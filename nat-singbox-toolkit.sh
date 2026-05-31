#!/usr/bin/env bash
set -euo pipefail

VERSION="0.1.0"
FSCARMEN_URL="${FSCARMEN_URL:-https://raw.githubusercontent.com/fscarmen/sing-box/main/sing-box.sh}"
# 发布到 GitHub 后建议改成你的仓库 raw 地址，或运行时通过 ROUTE_HELPER_URL 覆盖。
ROUTE_HELPER_URL="${ROUTE_HELPER_URL:-https://raw.githubusercontent.com/jiwen77/nat-singbox-toolkit/main/apply-singbox-authuser-routes.sh}"
CONF_DIR="${CONF_DIR:-/etc/sing-box/conf}"
SINGBOX_BIN_DEFAULT="/etc/sing-box/sing-box"
SERVICE_NAME="${SERVICE_NAME:-sing-box}"

if [[ -t 1 ]]; then
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  RED=$'\033[31m'
  BOLD=$'\033[1m'
  NC=$'\033[0m'
else
  GREEN=''
  YELLOW=''
  RED=''
  BOLD=''
  NC=''
fi
info() { printf "${GREEN}==>${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}WARN:${NC} %s\n" "$*" >&2; }
err() { printf "${RED}ERROR:${NC} %s\n" "$*" >&2; }
title() { printf "\n${BOLD}%s${NC}\n" "$*"; }

pause() { read -r -p "按 Enter 返回菜单..." _ || true; }

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

confirm() {
  local label="$1" default="${2:-y}" value suffix
  [[ "$default" =~ ^[Yy]$ ]] && suffix="Y/n" || suffix="y/N"
  read -r -p "$label [$suffix]: " value || true
  value="${value:-$default}"
  [[ "$value" =~ ^[Yy]$ ]]
}

is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

require_root() {
  if ! is_root; then
    err "请用 root 运行。"
    exit 1
  fi
}

pkg_install() {
  local pkgs=("$@")
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${pkgs[@]}"
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y "${pkgs[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${pkgs[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${pkgs[@]}"
  else
    err "未知包管理器，请手动安装：${pkgs[*]}"
    return 1
  fi
}

ensure_basic_tools() {
  local missing=()
  for c in bash curl wget python3 ssh; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    info "基础工具已齐。"
    return 0
  fi
  warn "缺少工具：${missing[*]}"
  if confirm "是否自动安装常用依赖" y; then
    # Alpine openssh-client 包含 ssh；Debian 包名是 openssh-client。
    if command -v apk >/dev/null 2>&1; then
      pkg_install bash curl wget python3 openssh-client ca-certificates
    else
      pkg_install bash curl wget python3 openssh-client ca-certificates
    fi
  fi
}

singbox_bin() {
  if [[ -x "$SINGBOX_BIN_DEFAULT" ]]; then
    printf '%s\n' "$SINGBOX_BIN_DEFAULT"
  elif command -v sing-box >/dev/null 2>&1; then
    command -v sing-box
  else
    printf '%s\n' ''
  fi
}

service_restart() {
  local svc="$1"
  if command -v rc-service >/dev/null 2>&1; then
    rc-service "$svc" restart
  elif command -v systemctl >/dev/null 2>&1; then
    systemctl restart "$svc"
  else
    warn "找不到 rc-service/systemctl，请手动重启 $svc。"
  fi
}

service_start_enable() {
  local svc="$1"
  if command -v rc-update >/dev/null 2>&1; then
    rc-update add "$svc" default >/dev/null 2>&1 || true
    rc-service "$svc" restart
  elif command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl enable --now "$svc"
  else
    warn "找不到服务管理器，请手动启动 $svc。"
  fi
}

show_status() {
  title "状态总览"
  echo "版本: nat-singbox-toolkit $VERSION"
  echo "配置目录: $CONF_DIR"
  echo
  echo "--- OS ---"
  (cat /etc/os-release 2>/dev/null || true) | sed -n '1,8p'
  echo
  echo "--- 资源 ---"
  free -h 2>/dev/null || true
  df -h / 2>/dev/null || true
  echo
  echo "--- 监听端口 ---"
  (ss -lntup 2>/dev/null || netstat -lntup 2>/dev/null || true) | sed -E 's/users:\(\([^)]*\)\)//g' | grep -E '(:22|sing-box|ssh|108[0-9]|443|444|xray|nginx)' || true
  echo
  echo "--- 服务 ---"
  if command -v rc-status >/dev/null 2>&1; then
    rc-status 2>/dev/null | grep -Ei 'sing-box|socks|ssh|xray|argo|nginx' || true
  elif command -v systemctl >/dev/null 2>&1; then
    systemctl --no-pager --type=service --state=running 2>/dev/null | grep -Ei 'sing-box|socks|ssh|xray|argo|nginx' || true
  fi
  echo
  echo "--- sing-box 配置摘要 ---"
  if [[ -d "$CONF_DIR" ]] && command -v python3 >/dev/null 2>&1; then
    python3 - "$CONF_DIR" <<'PY'
import json, sys
from pathlib import Path
conf = Path(sys.argv[1])
for path in sorted(conf.glob('*.json')):
    try:
        data = json.load(open(path))
    except Exception as e:
        print(f"! {path.name}: {e}")
        continue
    for inbound in data.get('inbounds', []) or []:
        users = inbound.get('users') or []
        print(f"IN  {inbound.get('tag')} type={inbound.get('type')} port={inbound.get('listen_port')} users={[u.get('name') for u in users]}")
    for outbound in data.get('outbounds', []) or []:
        print(f"OUT {outbound.get('tag')} type={outbound.get('type')} target={outbound.get('server','')}:{outbound.get('server_port','')}")
    route = data.get('route')
    if isinstance(route, dict):
        print(f"ROUTE final={route.get('final')} rules={len(route.get('rules') or [])}")
PY
  fi
  echo
  local sb; sb="$(singbox_bin)"
  if [[ -n "$sb" && -d "$CONF_DIR" ]]; then
    echo "--- sing-box check ---"
    "$sb" check -C "$CONF_DIR" || true
  else
    warn "未找到 sing-box 或配置目录。"
  fi
}

install_singbox_reality_recommended() {
  title "安装 sing-box 底座：Reality-only 推荐模式"
  require_root
  ensure_basic_tools
  local start_port server_ip node_name port_nginx
  prompt start_port "内部监听端口 / START_PORT" "443"
  default_ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  prompt server_ip "公网 IP/域名（NAT 小鸡填公网 IP）" "$default_ip"
  prompt node_name "节点名" "nat-singbox"
  port_nginx="n"
  echo
  echo "将调用 fscarmen/sing-box："
  echo "  --CHOOSE_PROTOCOLS b   # XTLS + Reality"
  echo "  --START_PORT $start_port"
  echo "  --PORT_NGINX n         # 不开订阅 nginx"
  echo "  --SERVER_IP $server_ip"
  echo "  --NODE_NAME_CONFIRM $node_name"
  echo
  warn "这会执行上游脚本：$FSCARMEN_URL"
  if ! confirm "确认继续" y; then return 0; fi
  bash <(wget -qO- "$FSCARMEN_URL") \
    --LANGUAGE c \
    --CHOOSE_PROTOCOLS b \
    --START_PORT "$start_port" \
    --PORT_NGINX "$port_nginx" \
    --SERVER_IP "$server_ip" \
    --NODE_NAME_CONFIRM "$node_name"
}

run_fscarmen_menu() {
  title "打开 fscarmen/sing-box 原生菜单"
  require_root
  ensure_basic_tools
  warn "即将执行上游脚本：$FSCARMEN_URL"
  if confirm "继续打开原生菜单" y; then
    bash <(wget -qO- "$FSCARMEN_URL")
  fi
}

setup_ssh_socks_landing() {
  title "配置 SSH SOCKS 落地隧道"
  require_root
  ensure_basic_tools
  local name host port user local_port key_file service_name pubkey
  prompt name "落地名称（用于服务名，例如 landing）" "landing"
  prompt host "落地 SSH 主机/IP" "203.0.113.10"
  prompt port "落地 SSH 端口" "22222"
  prompt user "落地 SSH 用户" "root"
  prompt local_port "本地 SOCKS 监听端口" "1081"
  key_file="/root/.ssh/${name}_ed25519"
  prompt key_file "专用 SSH key 路径" "$key_file"
  mkdir -p "$(dirname "$key_file")"
  chmod 700 "$(dirname "$key_file")"
  if [[ ! -f "$key_file" ]]; then
    info "生成 SSH key: $key_file"
    ssh-keygen -t ed25519 -f "$key_file" -N "" -C "$(hostname)-to-${name}"
  fi
  pubkey="$(cat "$key_file.pub")"
  echo
  echo "请确认落地机 ${user}@${host}:${port} 的 authorized_keys 已包含下面公钥："
  echo "$pubkey"
  echo
  if confirm "是否现在尝试通过 SSH 自动追加公钥到落地机（可能需要输入密码）" n; then
    cat "$key_file.pub" | ssh -p "$port" \
      -o StrictHostKeyChecking=accept-new \
      "${user}@${host}" 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
  fi
  service_name="${name}-socks"
  echo
  info "测试免密连接和本地 SOCKS 监听会在服务启动后进行。"

  if command -v rc-service >/dev/null 2>&1; then
    cat > "/etc/init.d/${service_name}" <<EOF
#!/sbin/openrc-run

name="${service_name}"
description="SSH dynamic SOCKS tunnel to ${name}"

supervisor=supervise-daemon
command="/usr/bin/ssh"
command_args="-i ${key_file} -N -D 127.0.0.1:${local_port} -p ${port} -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes ${user}@${host}"

respawn_delay=5
respawn_max=0

output_log="/var/log/${service_name}.log"
error_log="/var/log/${service_name}.log"

depend() {
    need net
}
EOF
    chmod +x "/etc/init.d/${service_name}"
  elif command -v systemctl >/dev/null 2>&1; then
    cat > "/etc/systemd/system/${service_name}.service" <<EOF
[Unit]
Description=SSH dynamic SOCKS tunnel to ${name}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/ssh -i ${key_file} -N -D 127.0.0.1:${local_port} -p ${port} -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes ${user}@${host}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  else
    err "不支持的服务管理器，请手动创建服务。"
    return 1
  fi

  service_start_enable "$service_name"
  echo
  info "检查本地 SOCKS：127.0.0.1:${local_port}"
  ss -lntp 2>/dev/null | grep ":${local_port}" || true
  if command -v curl >/dev/null 2>&1; then
    echo "直出 IP:"
    curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true; echo
    echo "SOCKS 出口 IP:"
    curl -4fsS --socks5-hostname "127.0.0.1:${local_port}" --max-time 12 https://api.ipify.org 2>/dev/null || true; echo
  fi
}

run_route_helper() {
  title "应用 sing-box auth_user 分流"
  require_root
  ensure_basic_tools
  local self_dir helper tmp
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  helper="${self_dir}/apply-singbox-authuser-routes.sh"
  if [[ -x "$helper" ]]; then
    CONF_DIR="$CONF_DIR" bash "$helper"
    return
  fi
  if command -v apply-singbox-authuser-routes.sh >/dev/null 2>&1; then
    CONF_DIR="$CONF_DIR" apply-singbox-authuser-routes.sh
    return
  fi
  warn "未在本地找到 apply-singbox-authuser-routes.sh，将从 ROUTE_HELPER_URL 下载：$ROUTE_HELPER_URL"
  if ! confirm "确认下载并执行分流 helper" y; then return 0; fi
  tmp="$(mktemp /tmp/apply-nat-singbox-toolkits.XXXXXX.sh)"
  curl -fsSL "$ROUTE_HELPER_URL" -o "$tmp"
  chmod +x "$tmp"
  CONF_DIR="$CONF_DIR" bash "$tmp"
  rm -f "$tmp"
}

backup_conf() {
  title "备份 sing-box 配置"
  require_root
  if [[ ! -d "$CONF_DIR" ]]; then
    err "配置目录不存在: $CONF_DIR"
    return 1
  fi
  local dst
  dst="${CONF_DIR}.bak.manual-$(date +%Y%m%d-%H%M%S)"
  cp -a "$CONF_DIR" "$dst"
  info "已备份到：$dst"
}

check_and_restart() {
  title "检查并重启 sing-box"
  local sb; sb="$(singbox_bin)"
  if [[ -z "$sb" ]]; then
    err "未找到 sing-box。"
    return 1
  fi
  "$sb" check -C "$CONF_DIR"
  if confirm "配置检查通过，是否重启 $SERVICE_NAME" y; then
    service_restart "$SERVICE_NAME"
  fi
}

show_singbox_nodes() {
  title "节点摘要 / Remnawave Mihomo 片段"
  if ! command -v python3 >/dev/null 2>&1; then
    err "需要 python3 来解析 sing-box JSON。请先运行菜单 2 安装基础依赖。"
    return 1
  fi
  if [[ ! -d "$CONF_DIR" ]]; then
    err "配置目录不存在: $CONF_DIR"
    return 1
  fi
  python3 - "$CONF_DIR" <<'PY'
import json
import os
import re
import socket
import sys
import time
import urllib.request
from pathlib import Path

conf = Path(sys.argv[1])

def ask(prompt, default=""):
    if default is None:
        default = ""
    suffix = f" [{default}]" if str(default) else ""
    try:
        value = input(f"{prompt}{suffix}: ").strip()
    except EOFError:
        value = ""
    return value if value else str(default)

def yes_no(prompt, default="y"):
    suffix = "Y/n" if default.lower().startswith("y") else "y/N"
    try:
        value = input(f"{prompt} [{suffix}]: ").strip()
    except EOFError:
        value = ""
    value = value or default
    return value.lower().startswith("y")

def load_json_files():
    out = []
    for path in sorted(conf.glob("*.json")):
        try:
            out.append((path, json.load(open(path))))
        except Exception as e:
            print(f"! 跳过 {path.name}: JSON 读取失败: {e}")
    return out

def reality_meta(inbound):
    tls = inbound.get("tls") or {}
    reality = tls.get("reality") or {}
    handshake = reality.get("handshake") or {}
    sni = tls.get("server_name") or handshake.get("server") or ""
    short_id = reality.get("short_id", "")
    if isinstance(short_id, list):
        short_id = short_id[0] if short_id else ""
    elif short_id is None:
        short_id = ""
    fp = ""
    utls = tls.get("utls") or {}
    if isinstance(utls, dict):
        fp = utls.get("fingerprint") or ""
    return sni, str(short_id), fp or "firefox"

def clean_text(path):
    ansi = re.compile(r"\x1b\[[0-9;]*m")
    try:
        return ansi.sub("", path.read_text(errors="ignore"))
    except Exception:
        return ""

def guess_public_keys():
    paths = [
        Path("/etc/sing-box/list"),
        Path("/etc/sing-box/subscribe/proxies"),
        Path("/etc/sing-box/subscribe/clash"),
        Path("/etc/sing-box/subscribe/clash2"),
    ]
    patterns = [
        re.compile(r"(?:[?&]pbk=)([^&#\s]+)"),
        re.compile(r"public-key:\s*\"?([^\",}\s]+)\"?"),
        re.compile(r'"public_key"\s*:\s*"([^"]+)"'),
        re.compile(r"public_key:\s*\"?([^\",}\s]+)\"?"),
    ]
    keys = []
    for path in paths:
        if not path.is_file():
            continue
        text = clean_text(path)
        for pat in patterns:
            for match in pat.finditer(text):
                key = match.group(1)
                if key and key not in keys:
                    keys.append(key)
    return keys

def detect_public_ip():
    try:
        with urllib.request.urlopen("https://api.ipify.org", timeout=5) as r:
            return r.read().decode().strip()
    except Exception:
        return ""

def yaml_quote(value):
    value = "" if value is None else str(value)
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

files = load_json_files()
inbounds = []
outbounds = []
auth_routes = {}

for path, data in files:
    for inbound in data.get("inbounds", []) or []:
        blob = json.dumps(inbound).lower()
        if inbound.get("type") == "vless" and ("reality" in blob or inbound.get("tls")):
            sni, short_id, fp = reality_meta(inbound)
            inbounds.append({
                "file": path.name,
                "tag": inbound.get("tag") or "",
                "listen": inbound.get("listen") or "",
                "listen_port": inbound.get("listen_port") or inbound.get("port") or "",
                "users": inbound.get("users") or [],
                "sni": sni,
                "short_id": short_id,
                "fingerprint": fp,
            })
    for outbound in data.get("outbounds", []) or []:
        outbounds.append(outbound)
    route = data.get("route")
    if isinstance(route, dict):
        for rule in route.get("rules") or []:
            if not isinstance(rule, dict):
                continue
            users = rule.get("auth_user")
            inbound_tags = rule.get("inbound")
            outbound = rule.get("outbound")
            if not users or not outbound:
                continue
            if isinstance(users, str):
                users = [users]
            if isinstance(inbound_tags, str):
                inbound_tags = [inbound_tags]
            inbound_tags = inbound_tags or ["*"]
            for tag in inbound_tags:
                for user in users:
                    auth_routes[(tag, user)] = outbound

print("--- VLESS/Reality inbound 摘要 ---")
if not inbounds:
    print("未发现 VLESS/Reality inbound。")
    raise SystemExit

for idx, inbound in enumerate(inbounds, 1):
    print(f"{idx}. tag={inbound['tag']} file={inbound['file']} listen={inbound['listen'] or '*'}:{inbound['listen_port']} sni={inbound['sni'] or '(unknown)'} short-id={inbound['short_id']!r}")
    users = inbound["users"]
    if not users:
        print("   users: (empty)")
    for user in users:
        name = user.get("name") or "(no-name)"
        uuid = user.get("uuid") or ""
        route = auth_routes.get((inbound["tag"], name)) or auth_routes.get(("*", name)) or "default/final"
        print(f"   - user={name} uuid={uuid} -> {route}")

print("\n--- outbound 摘要 ---")
if outbounds:
    for outbound in outbounds:
        target = ""
        if outbound.get("server"):
            target = f" {outbound.get('server')}:{outbound.get('server_port', '')}"
        print(f"- {outbound.get('tag')} ({outbound.get('type')}){target}")
else:
    print("(none)")

if not yes_no("\n是否生成 Remnawave/Mihomo proxies 片段", "y"):
    print("已跳过 Mihomo 片段生成。")
    raise SystemExit

public_ip = detect_public_ip()
keys = guess_public_keys()
default_key = keys[0] if len(keys) == 1 else ""
if len(keys) > 1:
    print("\n检测到多个 public-key，下面会按 inbound 逐个确认。")

hostname = socket.gethostname()
all_lines = []
for inbound in inbounds:
    print(f"\n--- 生成 inbound: {inbound['tag']} ({inbound['listen_port']}) ---")
    prefix_default = inbound["tag"] or hostname
    prefix = ask("节点名前缀", prefix_default)
    server = ask("公网 IP/域名（自动检测不准可改）", public_ip)
    port = ask("公网端口（NAT 映射端口；公网=内网可回车）", inbound["listen_port"])
    sni = ask("Reality servername/SNI", inbound["sni"])
    short_id = ask("Reality short-id（空 short-id 直接回车）", inbound["short_id"])
    key_default = default_key
    if len(keys) > 1:
        print("可选 public-key:")
        for i, key in enumerate(keys, 1):
            print(f"  {i}) {key}")
        selected = ask("Reality public-key（可粘贴或输入序号）", "1")
        if selected.isdigit() and 1 <= int(selected) <= len(keys):
            key_default = keys[int(selected) - 1]
        else:
            key_default = selected
    public_key = ask("Reality public-key", key_default)
    fingerprint = ask("client-fingerprint", inbound["fingerprint"] or "firefox")

    for n, user in enumerate(inbound["users"], 1):
        uuid = user.get("uuid") or ""
        if not uuid:
            continue
        user_name = user.get("name") or f"user{n}"
        flow = user.get("flow") or "xtls-rprx-vision"
        node_name = f"{prefix}-{user_name}"
        all_lines.extend([
            f"  - name: {node_name}",
            "    type: vless",
            f"    server: {server or '<SERVER_OR_IP>'}",
            f"    port: {port or '<PUBLIC_PORT>'}",
            f"    uuid: {yaml_quote(uuid)}",
            "    network: tcp",
            "    tls: true",
            "    udp: false",
            f"    flow: {flow}",
            f"    servername: {sni or '<REALITY_SNI>'}",
            f"    client-fingerprint: {fingerprint or 'firefox'}",
            "    reality-opts:",
            f"      public-key: {yaml_quote(public_key or '<REALITY_PUBLIC_KEY>')}",
            f"      short-id: {yaml_quote(short_id)}",
            "",
        ])

print("\n--- Remnawave/Mihomo proxies snippet ---")
print("\n".join(all_lines))

out_dir = Path("/root") if os.geteuid() == 0 else Path.cwd()
stamp = time.strftime("%Y%m%d-%H%M%S")
out_file = out_dir / f"nat-singbox-toolkit-mihomo-{stamp}.yaml"
out_file.write_text("\n".join(all_lines))
print(f"MIHOMO_SNIPPET={out_file}")

if yes_no("\n是否查看 fscarmen 原始节点文件（输出可能很长）", "n"):
    for path in [Path("/etc/sing-box/list"), Path("/etc/sing-box/subscribe/proxies"), Path("/etc/sing-box/subscribe/clash")]:
        if path.is_file():
            print(f"\n--- {path} ---")
            print(path.read_text(errors="ignore")[:20000])
PY
}

menu() {
  clear || true
  cat <<EOF
${BOLD}NAT sing-box Toolkit v${VERSION}${NC}

1. 状态总览 / sing-box check
2. 安装基础依赖
3. 安装 sing-box Reality-only 底座（调用 fscarmen，推荐）
4. 打开 fscarmen/sing-box 原生菜单
5. 配置 SSH SOCKS 落地隧道（例如 landing）
6. 应用 auth_user 多落地分流
7. 节点摘要 / 生成 Remnawave Mihomo 片段
8. 备份 sing-box 配置
9. 检查并重启 sing-box
0. 退出
EOF
}

main_loop() {
  require_root
  while true; do
    menu
    read -r -p "请选择: " choice || true
    case "${choice:-}" in
      1) show_status; pause ;;
      2) ensure_basic_tools; pause ;;
      3) install_singbox_reality_recommended; pause ;;
      4) run_fscarmen_menu; pause ;;
      5) setup_ssh_socks_landing; pause ;;
      6) run_route_helper; pause ;;
      7) show_singbox_nodes; pause ;;
      8) backup_conf; pause ;;
      9) check_and_restart; pause ;;
      0) exit 0 ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}

main_loop "$@"
