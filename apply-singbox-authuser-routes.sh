#!/usr/bin/env bash
set -euo pipefail

VERSION="0.1.1"
DEFAULT_CONF_DIR="/etc/sing-box/conf"
DEFAULT_SERVICE="sing-box"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '\033[32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mWARN:\033[0m %s\n' "$*" >&2; }
err() { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
apply-singbox-authuser-routes.sh

交互式给已安装的 sing-box Reality/VLESS 底座增加多落地分流：
- 同一个 Reality inbound / 同一个公网端口
- 多个 VLESS UUID / users.name
- route.rules 按 auth_user 分流到不同 outbound

用法：
  bash apply-singbox-authuser-routes.sh

环境变量可选：
  CONF_DIR=/etc/sing-box/conf      sing-box conf.d 目录
  NO_RESTART=1                     应用后不询问重启

注意：
  这个脚本不安装 sing-box，不建立 SSH 隧道；只修改 sing-box JSON 配置。
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

prompt() {
  local var_name="$1" label="$2" default="${3:-}" value
  if [[ -n "$default" ]]; then
    read -r -p "$label [$default]: " value || true
    value="${value:-$default}"
  else
    read -r -p "$label: " value || true
  fi
  printf -v "$var_name" '%s' "$value"
}

prompt_yes_no() {
  local var_name="$1" label="$2" default="${3:-y}" value suffix
  if [[ "$default" =~ ^[Yy]$ ]]; then suffix="Y/n"; else suffix="y/N"; fi
  read -r -p "$label [$suffix]: " value || true
  value="${value:-$default}"
  if [[ "$value" =~ ^[Yy]$ ]]; then
    printf -v "$var_name" 'yes'
  else
    printf -v "$var_name" 'no'
  fi
}

prompt_secret_optional() {
  local var_name="$1" label="$2" value
  read -r -s -p "$label（可空）: " value || true
  printf '\n'
  printf -v "$var_name" '%s' "$value"
}

gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
  fi
}

need_python() {
  if command -v python3 >/dev/null 2>&1; then
    return 0
  fi
  err "需要 python3 来安全修改 JSON。"
  if command -v apk >/dev/null 2>&1; then
    prompt_yes_no install_py "检测到 Alpine/apk，是否现在安装 python3" y
    if [[ "$install_py" == "yes" ]]; then
      apk add --no-cache python3
      return 0
    fi
  fi
  exit 1
}

py_detect_first_tag() {
  python3 - "$1" <<'PY'
import json, sys
from pathlib import Path

def load_jsonc(path):
    text = path.read_text(errors='ignore')
    if not text.strip():
        raise ValueError('空文件')
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        # fscarmen may prepend helper lines like: // "public_key":"..."
        text = '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('//'))
        return json.loads(text)

conf = Path(sys.argv[1])
for path in sorted(conf.glob('*.json')):
    try:
        data = load_jsonc(path)
    except Exception:
        continue
    for inbound in data.get('inbounds', []) or []:
        blob = json.dumps(inbound).lower()
        if inbound.get('type') == 'vless' and ('reality' in blob or inbound.get('tls')):
            print(inbound.get('tag', ''))
            raise SystemExit
PY
}

py_list_inbounds() {
  python3 - "$1" <<'PY'
import json, sys
from pathlib import Path

def load_jsonc(path):
    text = path.read_text(errors='ignore')
    if not text.strip():
        raise ValueError('空文件')
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        text = '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('//'))
        return json.loads(text)

conf = Path(sys.argv[1])
found = False
for path in sorted(conf.glob('*.json')):
    try:
        data = load_jsonc(path)
    except Exception as e:
        print(f"  ! {path.name}: JSON 读取失败: {e}")
        continue
    for inbound in data.get('inbounds', []) or []:
        blob = json.dumps(inbound).lower()
        if inbound.get('type') == 'vless' and ('reality' in blob or inbound.get('tls')):
            found = True
            users = inbound.get('users') or []
            user_desc = ', '.join([f"{u.get('name','(no-name)')}={u.get('uuid','')}" for u in users]) or '(no users)'
            print(f"  - tag={inbound.get('tag')} file={path.name} listen_port={inbound.get('listen_port')} users=[{user_desc}]")
if not found:
    print("  ! 未发现 VLESS/Reality inbound")
PY
}

py_first_user_uuid() {
  python3 - "$1" "$2" <<'PY'
import json, sys
from pathlib import Path

def load_jsonc(path):
    text = path.read_text(errors='ignore')
    if not text.strip():
        raise ValueError('空文件')
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        text = '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('//'))
        return json.loads(text)

conf = Path(sys.argv[1]); tag = sys.argv[2]
for path in sorted(conf.glob('*.json')):
    try: data = load_jsonc(path)
    except Exception: continue
    for inbound in data.get('inbounds', []) or []:
        if inbound.get('tag') == tag:
            users = inbound.get('users') or []
            if users:
                print(users[0].get('uuid',''))
            raise SystemExit
PY
}

py_suggest_sni_shortid() {
  python3 - "$1" "$2" <<'PY'
import json, sys
from pathlib import Path

def load_jsonc(path):
    text = path.read_text(errors='ignore')
    if not text.strip():
        raise ValueError('空文件')
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        text = '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('//'))
        return json.loads(text)

conf = Path(sys.argv[1]); tag = sys.argv[2]
for path in sorted(conf.glob('*.json')):
    try: data = load_jsonc(path)
    except Exception: continue
    for inbound in data.get('inbounds', []) or []:
        if inbound.get('tag') != tag:
            continue
        tls = inbound.get('tls') or {}
        reality = tls.get('reality') or {}
        sni = tls.get('server_name') or (reality.get('handshake') or {}).get('server') or ''
        sid = ''
        short_id = reality.get('short_id', '')
        if isinstance(short_id, list) and short_id:
            sid = str(short_id[0])
        elif isinstance(short_id, str):
            sid = short_id
        print(sni)
        print(sid)
        raise SystemExit
print('')
print('')
PY
}

py_inbound_listen_port() {
  python3 - "$1" "$2" <<'PY'
import json, sys
from pathlib import Path

def load_jsonc(path):
    text = path.read_text(errors='ignore')
    if not text.strip():
        raise ValueError('空文件')
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        text = '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('//'))
        return json.loads(text)

conf = Path(sys.argv[1]); tag = sys.argv[2]
for path in sorted(conf.glob('*.json')):
    try: data = load_jsonc(path)
    except Exception: continue
    for inbound in data.get('inbounds', []) or []:
        if inbound.get('tag') == tag:
            print(inbound.get('listen_port', '') or '')
            raise SystemExit
PY
}

guess_public_key_from_outputs() {
  python3 - "${CONF_DIR:-$DEFAULT_CONF_DIR}" <<'PY'
import re
import sys
from pathlib import Path

conf = Path(sys.argv[1])
paths = [
    *sorted(conf.glob('*.json')),
    Path('/etc/sing-box/list'),
    Path('/etc/sing-box/subscribe/proxies'),
    Path('/etc/sing-box/subscribe/clash'),
    Path('/etc/sing-box/subscribe/clash2'),
]

ansi = re.compile(r'\x1b\[[0-9;]*m')
patterns = [
    re.compile(r'(?:[?&]pbk=)([^&#\s]+)'),
    re.compile(r'public-key:\s*"?([^",}\s]+)"?'),
    re.compile(r'"public_key"\s*:\s*"([^"]+)"'),
    re.compile(r'public_key:\s*"?([^",}\s]+)"?'),
]

for path in paths:
    if not path.is_file():
        continue
    try:
        text = ansi.sub('', path.read_text(errors='ignore'))
    except Exception:
        continue
    for pat in patterns:
        m = pat.search(text)
        if m:
            print(m.group(1))
            raise SystemExit
PY
}

init_plan() {
  local plan_file="$1"
  python3 - "$plan_file" <<'PY'
import json, sys
with open(sys.argv[1], 'w') as f:
    json.dump({"routes": []}, f)
PY
}

set_plan_base() {
  local plan_file="$1"
  PLAN_CONF_DIR="$CONF_DIR" \
  PLAN_INBOUND_TAG="$INBOUND_TAG" \
  PLAN_DIRECT_NAME="$DIRECT_NAME" \
  PLAN_DIRECT_UUID="$DIRECT_UUID" \
  PLAN_SET_FINAL_DIRECT="$SET_FINAL_DIRECT" \
  PLAN_PUBLIC_SERVER="$PUBLIC_SERVER" \
  PLAN_PUBLIC_PORT="$PUBLIC_PORT" \
  PLAN_SNI="$REALITY_SNI" \
  PLAN_PUBLIC_KEY="$REALITY_PUBLIC_KEY" \
  PLAN_SHORT_ID="$REALITY_SHORT_ID" \
  python3 - "$plan_file" <<'PY'
import json, os, sys
p = sys.argv[1]
data = json.load(open(p))
data.update({
    "conf_dir": os.environ["PLAN_CONF_DIR"],
    "inbound_tag": os.environ["PLAN_INBOUND_TAG"],
    "direct": {
        "name": os.environ["PLAN_DIRECT_NAME"],
        "uuid": os.environ["PLAN_DIRECT_UUID"],
    },
    "set_final_direct": os.environ["PLAN_SET_FINAL_DIRECT"] == "yes",
    "public": {
        "server": os.environ.get("PLAN_PUBLIC_SERVER", ""),
        "port": os.environ.get("PLAN_PUBLIC_PORT", ""),
        "sni": os.environ.get("PLAN_SNI", ""),
        "public_key": os.environ.get("PLAN_PUBLIC_KEY", ""),
        "short_id": os.environ.get("PLAN_SHORT_ID", ""),
    },
})
json.dump(data, open(p, 'w'), indent=2, ensure_ascii=False)
PY
}

add_route_to_plan() {
  local plan_file="$1"
  ROUTE_USER="$ROUTE_USER" ROUTE_UUID="$ROUTE_UUID" OUTBOUND_TAG="$OUTBOUND_TAG" \
  OUTBOUND_MODE="$OUTBOUND_MODE" SOCKS_SERVER="$SOCKS_SERVER" SOCKS_PORT="$SOCKS_PORT" \
  SOCKS_USERNAME="$SOCKS_USERNAME" SOCKS_PASSWORD="$SOCKS_PASSWORD" \
  python3 - "$plan_file" <<'PY'
import json, os, sys
p = sys.argv[1]
data = json.load(open(p))
route = {
    "user": os.environ["ROUTE_USER"],
    "uuid": os.environ["ROUTE_UUID"],
    "outbound_tag": os.environ["OUTBOUND_TAG"],
    "outbound_mode": os.environ["OUTBOUND_MODE"],
    "socks": {
        "server": os.environ.get("SOCKS_SERVER", ""),
        "port": int(os.environ.get("SOCKS_PORT") or 0),
        "username": os.environ.get("SOCKS_USERNAME", ""),
        "password": os.environ.get("SOCKS_PASSWORD", ""),
    },
}
data.setdefault("routes", []).append(route)
json.dump(data, open(p, 'w'), indent=2, ensure_ascii=False)
PY
}

apply_plan() {
  local plan_file="$1"
  python3 - "$plan_file" <<'PY'
import copy
import json
import os
import shutil
import sys
import time
from pathlib import Path

plan = json.load(open(sys.argv[1]))
conf = Path(plan["conf_dir"])
if not conf.is_dir():
    raise SystemExit(f"配置目录不存在: {conf}")

def load_jsonc(path):
    text = path.read_text(errors='ignore')
    if not text.strip():
        raise ValueError('空文件')
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        # fscarmen may prepend helper lines like: // "public_key":"..."
        text = '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('//'))
        return json.loads(text)

# Load all json files in conf.d style directory.
files = []
for path in sorted(conf.glob('*.json')):
    try:
        files.append((path, load_jsonc(path)))
    except Exception as e:
        raise SystemExit(f"JSON 读取失败 {path}: {e}")

inbound_tag = plan["inbound_tag"]
in_file = in_cfg = inbound = None
for path, data in files:
    for item in data.get('inbounds', []) or []:
        if item.get('tag') == inbound_tag:
            in_file, in_cfg, inbound = path, data, item
            break
    if inbound is not None:
        break
if inbound is None:
    raise SystemExit(f"找不到 inbound tag: {inbound_tag}")
if inbound.get('type') != 'vless':
    raise SystemExit(f"inbound {inbound_tag} 不是 vless: {inbound.get('type')}")

# Find outbounds and route files.
out_file = out_cfg = None
route_file = route_cfg = None
for path, data in files:
    if out_cfg is None and isinstance(data.get('outbounds'), list):
        out_file, out_cfg = path, data
    if route_cfg is None and isinstance(data.get('route'), dict):
        route_file, route_cfg = path, data
if out_cfg is None:
    raise SystemExit("找不到包含 outbounds 的 JSON 文件")
if route_cfg is None:
    raise SystemExit("找不到包含 route 的 JSON 文件")

stamp = time.strftime('%Y%m%d-%H%M%S')
backup = conf.parent / f"{conf.name}.bak.authuser-route-{stamp}"
shutil.copytree(conf, backup)
print(f"BACKUP={backup}")

users = inbound.setdefault('users', [])
if not isinstance(users, list):
    raise SystemExit(f"inbound {inbound_tag} users 不是数组")

# Infer flow from existing user or default.
flow = ''
for u in users:
    if u.get('flow'):
        flow = u.get('flow')
        break
flow = flow or 'xtls-rprx-vision'

def upsert_user(name, uuid, prefer_first=False):
    if not uuid:
        raise SystemExit(f"用户 {name} uuid 为空")
    # If UUID already exists, just ensure name/flow.
    for u in users:
        if u.get('uuid') == uuid:
            u.setdefault('name', name)
            u.setdefault('flow', flow)
            return
    # If direct user wants to reuse first blank user, update it.
    if prefer_first and users:
        users[0].setdefault('name', name)
        if not users[0].get('uuid'):
            users[0]['uuid'] = uuid
        users[0].setdefault('flow', flow)
        return
    # If user name exists, update uuid.
    for u in users:
        if u.get('name') == name:
            u['uuid'] = uuid
            u.setdefault('flow', flow)
            return
    users.append({"name": name, "uuid": uuid, "flow": flow})

# Direct: keep first existing UUID when possible, add name if missing.
direct = plan.get('direct') or {}
upsert_user(direct.get('name') or 'direct', direct.get('uuid'), prefer_first=True)

# Outbounds.
outbounds = out_cfg.setdefault('outbounds', [])
if not isinstance(outbounds, list):
    raise SystemExit("outbounds 不是数组")

def upsert_outbound(obj):
    tag = obj.get('tag')
    for i, item in enumerate(outbounds):
        if item.get('tag') == tag:
            outbounds[i] = obj
            return
    outbounds.append(obj)

# Route rules.
route = route_cfg.setdefault('route', {})
rules = route.setdefault('rules', [])
if not isinstance(rules, list):
    raise SystemExit("route.rules 不是数组")

route_users = []
for r in plan.get('routes', []):
    name = r['user']
    uuid = r['uuid']
    outbound_tag = r['outbound_tag']
    route_users.append(name)
    upsert_user(name, uuid, prefer_first=False)
    if r.get('outbound_mode') != 'existing':
        socks = r.get('socks') or {}
        obj = {
            "type": "socks",
            "tag": outbound_tag,
            "server": socks.get('server') or '127.0.0.1',
            "server_port": int(socks.get('port') or 1080),
            "version": "5",
        }
        if socks.get('username'):
            obj['username'] = socks.get('username')
        if socks.get('password'):
            obj['password'] = socks.get('password')
        upsert_outbound(obj)

# Remove prior rules for these auth_user names on this inbound, then prepend new rules.
def rule_matches_managed(rule):
    if not isinstance(rule, dict):
        return False
    inbound = rule.get('inbound')
    auth_user = rule.get('auth_user')
    inbound_list = inbound if isinstance(inbound, list) else ([inbound] if inbound else [])
    user_list = auth_user if isinstance(auth_user, list) else ([auth_user] if auth_user else [])
    return inbound_tag in inbound_list and any(u in route_users for u in user_list)

rules[:] = [r for r in rules if not rule_matches_managed(r)]
new_rules = []
for r in plan.get('routes', []):
    new_rules.append({
        "inbound": [inbound_tag],
        "auth_user": [r['user']],
        "outbound": r['outbound_tag'],
        "action": "route",
    })
rules[:0] = new_rules

if plan.get('set_final_direct'):
    route['final'] = 'direct'

# Save modified files.
def save(path, data):
    with open(path, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write('\n')

save(in_file, in_cfg)
save(out_file, out_cfg)
save(route_file, route_cfg)

# Generate snippets.
public = plan.get('public') or {}
server = public.get('server') or '<SERVER_OR_IP>'
port = public.get('port') or str(inbound.get('listen_port') or '<PUBLIC_PORT>')
sni = public.get('sni') or '<REALITY_SNI>'
pbk = public.get('public_key') or '<REALITY_PUBLIC_KEY>'
sid = public.get('short_id')
if sid is None:
    sid = '<SHORT_ID>'

# collect final relevant users
user_by_name = {u.get('name'): u for u in users if u.get('name')}
items = []
items.append((f"{server}-direct", direct.get('uuid')))
for r in plan.get('routes', []):
    items.append((f"{server}-{r['user']}", r['uuid']))

snippet_lines = []
for name, uuid in items:
    snippet_lines.extend([
        f"  - name: {name}",
        "    type: vless",
        f"    server: {server}",
        f"    port: {port}",
        f"    uuid: \"{uuid}\"",
        "    network: tcp",
        "    tls: true",
        "    udp: false",
        "    flow: xtls-rprx-vision",
        f"    servername: {sni}",
        "    client-fingerprint: firefox",
        "    reality-opts:",
        f"      public-key: \"{pbk}\"",
        f"      short-id: \"{sid}\"",
        "",
    ])
summary = {
    "backup": str(backup),
    "inbound_file": str(in_file),
    "outbound_file": str(out_file),
    "route_file": str(route_file),
    "inbound_tag": inbound_tag,
    "users": [{"name": u.get('name'), "uuid": u.get('uuid')} for u in users],
    "routes": plan.get('routes', []),
}
out_dir = Path('/root') if os.geteuid() == 0 else Path.cwd()
summary_path = out_dir / f"singbox-authuser-route-summary-{stamp}.json"
snippet_path = out_dir / f"singbox-authuser-route-mihomo-{stamp}.yaml"
json.dump(summary, open(summary_path, 'w'), indent=2, ensure_ascii=False)
open(snippet_path, 'w').write('\n'.join(snippet_lines))
print(f"SUMMARY={summary_path}")
print(f"MIHOMO_SNIPPET={snippet_path}")
print("--- Mihomo snippet ---")
print('\n'.join(snippet_lines))
PY
}

find_singbox_bin() {
  if [[ -x /etc/sing-box/sing-box ]]; then
    printf '%s\n' /etc/sing-box/sing-box
  elif command -v sing-box >/dev/null 2>&1; then
    command -v sing-box
  else
    printf '%s\n' ''
  fi
}

restart_service() {
  local svc="$1"
  if command -v rc-service >/dev/null 2>&1; then
    rc-service "$svc" restart
  elif command -v systemctl >/dev/null 2>&1; then
    systemctl restart "$svc"
  else
    warn "找不到 rc-service/systemctl，请手动重启 sing-box。"
  fi
}

main() {
  bold "sing-box auth_user route helper v$VERSION"
  echo "用途：给已安装的 sing-box Reality/VLESS 增加单端口多 UUID 分流。"
  echo

  need_python

  CONF_DIR="${CONF_DIR:-$DEFAULT_CONF_DIR}"
  prompt CONF_DIR "sing-box 配置目录" "$CONF_DIR"
  if [[ ! -d "$CONF_DIR" ]]; then
    err "配置目录不存在: $CONF_DIR"
    exit 1
  fi

  info "检测到的 VLESS/Reality inbounds："
  py_list_inbounds "$CONF_DIR"
  DEFAULT_TAG="$(py_detect_first_tag "$CONF_DIR" || true)"
  if [[ -z "$DEFAULT_TAG" ]]; then
    err "未找到 VLESS/Reality inbound。请确认 fscarmen/sing-box 已安装并启用了 XTLS + Reality。"
    exit 1
  fi
  prompt INBOUND_TAG "要改的 inbound tag" "$DEFAULT_TAG"

  EXISTING_UUID="$(py_first_user_uuid "$CONF_DIR" "$INBOUND_TAG" || true)"
  if [[ -z "$EXISTING_UUID" ]]; then
    EXISTING_UUID="$(gen_uuid)"
    warn "inbound 没有现有用户，将创建 direct 用户。"
  fi
  prompt DIRECT_NAME "原始直出用户名" "direct"
  prompt DIRECT_UUID "原始直出 UUID（建议保留现有 UUID）" "$EXISTING_UUID"
  prompt_yes_no SET_FINAL_DIRECT "是否设置 route.final=direct，确保默认直出" y

  PLAN_FILE="$(mktemp /tmp/singbox-route-plan.XXXXXX.json)"
  trap 'rm -f "$PLAN_FILE"' EXIT
  init_plan "$PLAN_FILE"

  echo
  info "添加落地分流用户。每个用户会生成一个客户端静态节点；同 IP 同端口，仅 UUID 不同。"
  add_more="yes"
  first_route="yes"
  while [[ "$add_more" == "yes" ]]; do
    if [[ "$first_route" == "yes" ]]; then
      default_user="landing"
      default_socks_port="1081"
    else
      default_user="landing2"
      default_socks_port="1082"
    fi
    prompt ROUTE_USER "落地用户名/auth_user" "$default_user"
    ROUTE_UUID_DEFAULT="$(gen_uuid)"
    prompt ROUTE_UUID "${ROUTE_USER} UUID" "$ROUTE_UUID_DEFAULT"
    prompt OUTBOUND_TAG "${ROUTE_USER} 对应 outbound tag" "${ROUTE_USER}-socks"
    echo "Outbound 类型："
    echo "  1) 新增/更新 SOCKS5 outbound（默认，适合 SSH -D 127.0.0.1:1081）"
    echo "  2) 使用已有 outbound tag（不创建 outbound，只加 route）"
    prompt OUTBOUND_CHOICE "请选择" "1"
    if [[ "$OUTBOUND_CHOICE" == "2" ]]; then
      OUTBOUND_MODE="existing"
      SOCKS_SERVER=""
      SOCKS_PORT=""
      SOCKS_USERNAME=""
      SOCKS_PASSWORD=""
    else
      OUTBOUND_MODE="socks"
      prompt SOCKS_SERVER "SOCKS5 server" "127.0.0.1"
      prompt SOCKS_PORT "SOCKS5 port" "$default_socks_port"
      prompt SOCKS_USERNAME "SOCKS5 username（可空）" ""
      if [[ -n "$SOCKS_USERNAME" ]]; then
        prompt_secret_optional SOCKS_PASSWORD "SOCKS5 password"
      else
        SOCKS_PASSWORD=""
      fi
    fi
    add_route_to_plan "$PLAN_FILE"
    first_route="no"
    prompt_yes_no add_more "继续添加另一个落地用户吗" n
  done

  echo
  info "Mihomo 静态节点输出信息（可空；只是为了生成片段，不影响服务端配置）"
  DETECTED_PUBLIC_SERVER="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  SUGGESTED_PUBLIC_PORT="$(py_inbound_listen_port "$CONF_DIR" "$INBOUND_TAG" || true)"
  mapfile -t SUGGESTED_REALITY < <(py_suggest_sni_shortid "$CONF_DIR" "$INBOUND_TAG" || true)
  SUGGESTED_SNI="${SUGGESTED_REALITY[0]:-}"
  SUGGESTED_SHORT_ID="${SUGGESTED_REALITY[1]:-}"
  SUGGESTED_PUBLIC_KEY="$(guess_public_key_from_outputs || true)"
  prompt PUBLIC_SERVER "公网 IP/域名（用于生成 Mihomo；自动检测不准可改）" "$DETECTED_PUBLIC_SERVER"
  prompt PUBLIC_PORT "公网端口（NAT 映射端口；公网=内网可回车）" "$SUGGESTED_PUBLIC_PORT"
  prompt REALITY_SNI "Reality servername/SNI" "$SUGGESTED_SNI"
  prompt REALITY_SHORT_ID "Reality short-id（空 short-id 直接回车）" "$SUGGESTED_SHORT_ID"
  prompt REALITY_PUBLIC_KEY "Reality public-key（会尝试从 /etc/sing-box/list 自动读取）" "$SUGGESTED_PUBLIC_KEY"

  set_plan_base "$PLAN_FILE"

  echo
  info "将执行：备份配置 -> 修改 users/outbounds/route -> sing-box check -> 可选重启。"
  prompt_yes_no CONFIRM_APPLY "确认应用到 $CONF_DIR 吗" y
  if [[ "$CONFIRM_APPLY" != "yes" ]]; then
    warn "已取消。"
    exit 0
  fi

  apply_plan "$PLAN_FILE"

  SINGBOX_BIN="$(find_singbox_bin)"
  if [[ -n "$SINGBOX_BIN" ]]; then
    info "运行配置检查：$SINGBOX_BIN check -C $CONF_DIR"
    "$SINGBOX_BIN" check -C "$CONF_DIR"
  else
    warn "未找到 sing-box 可执行文件，跳过 check。"
  fi

  if [[ "${NO_RESTART:-}" != "1" ]]; then
    prompt_yes_no DO_RESTART "是否现在重启 sing-box 服务" y
    if [[ "$DO_RESTART" == "yes" ]]; then
      restart_service "$DEFAULT_SERVICE"
      info "已请求重启 $DEFAULT_SERVICE。"
    fi
  fi

  info "完成。建议检查：ss -lntp | grep sing-box；客户端导入输出的 Mihomo 片段后测试 direct/落地出口。"
}

main "$@"
