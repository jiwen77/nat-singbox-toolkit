# nat-singbox-toolkit

给已经安装好的 `sing-box` VLESS/Reality 底座增加“单端口多落地”分流。

适合：小 RAM / 小磁盘 NAT 机器，Remnawave 只负责 Mihomo 订阅模板，本机只跑轻量 sing-box。

## 设计

```text
同一个 Reality inbound / 同一个公网端口
  UUID_DIRECT / users.name=direct -> final/direct
  UUID_LANDING / users.name=landing -> outbound: landing-socks
```

客户端/Remnawave 静态节点里看起来是多个节点，但 IP、端口、Reality 参数相同，只有 UUID 不同。

## 前提

1. 已经安装 fscarmen/sing-box 或其他 sing-box 底座。
2. 已经有 VLESS + Reality inbound。
3. 如果要链某台落地机/其他出口，需要先在本机准备好本地 SOCKS，例如：

```bash
ssh -i /root/.ssh/landing_ed25519 \
  -N -D 127.0.0.1:1081 \
  -p 22222 \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  root@203.0.113.10
```

建议把 SSH SOCKS 做成 OpenRC/systemd 自启服务。

## 用法

```bash
bash <(curl -fsSL https://github.com/jiwen77/nat-singbox-toolkit/raw/refs/heads/main/apply-singbox-authuser-routes.sh)
```

或：

```bash
wget -O apply-singbox-authuser-routes.sh https://github.com/jiwen77/nat-singbox-toolkit/raw/refs/heads/main/apply-singbox-authuser-routes.sh
bash apply-singbox-authuser-routes.sh
```

默认配置目录：

```bash
/etc/sing-box/conf
```

可用环境变量覆盖：

```bash
CONF_DIR=/etc/sing-box/conf bash apply-singbox-authuser-routes.sh
NO_RESTART=1 bash apply-singbox-authuser-routes.sh
```

## 脚本会做什么

- 自动查找 VLESS/Reality inbound。
- 保留现有 UUID 作为 direct 节点。
- 交互式新增一个或多个 `auth_user` 用户。
- 为每个落地用户创建/更新 SOCKS5 outbound，或绑定到已有 outbound。
- 在 `route.rules` 最前面加入：

```json
{
  "inbound": ["你的 inbound tag"],
  "auth_user": ["landing"],
  "outbound": "landing-socks",
  "action": "route"
}
```

- 默认设置 `route.final = direct`。
- 自动备份整个配置目录。
- 运行 `sing-box check -C /etc/sing-box/conf`。
- 输出 Remnawave/Mihomo 可用的静态节点片段。
- 生成片段时会尽量自动读取公网 IP、inbound 端口、SNI、short-id、public-key；NAT 公网映射端口无法可靠自动发现时需要你确认。

## 参考

- sing-box VLESS inbound 支持 `users.name` / `users.uuid` / `users.flow`。
- sing-box route rule 支持 `auth_user` 匹配认证用户名。
- sing-box route action 的 `route` 会转发到指定 outbound。

## 集成菜单脚本

如果你想像工具箱一样使用，可以运行：

```bash
bash <(curl -fsSL https://github.com/jiwen77/nat-singbox-toolkit/raw/refs/heads/main/nat-singbox-toolkit.sh)
```

菜单包含：

```text
1. 状态总览 / sing-box check
2. 安装基础依赖
3. 安装 sing-box Reality-only 底座（调用 fscarmen，推荐）
4. 打开 fscarmen/sing-box 原生菜单
5. 配置 SSH SOCKS 落地隧道（例如 landing）
6. 应用 auth_user 多落地分流
7. 节点摘要 / 生成 Remnawave Mihomo 片段
8. 编辑 sing-box 配置文件（自动备份 + check）
9. 备份 sing-box 配置
10. 检查并重启 sing-box
11. 更新 toolkit 脚本
0. 退出
```

简易步骤：

```text
新 NAT 直连：
  1) 运行菜单 2 安装基础依赖
  2) 运行菜单 3 安装 sing-box Reality 底座
  3) 到 NAT 面板确认公网映射端口
  4) 运行菜单 7，生成 Remnawave/Mihomo proxies 节点片段

需要接落地：
  1) 先用菜单 5 建 SSH SOCKS 落地隧道
  2) 再用菜单 6 添加 auth_user 分流
  3) 最后用菜单 7 生成 direct / landing 两类节点片段

日常维护：
  - 菜单 1 看状态
  - 菜单 8 改 sing-box 配置
  - 菜单 10 check 并重启
  - 菜单 11 更新脚本
```

菜单 7 默认输出中等摘要：多 inbound/多端口、协议类型（例如 `vless / tcp / reality`）、SNI、fingerprint、short-id、users、outbounds，以及用户/入口对应的出口；不会输出整份 fscarmen 订阅、完整 JSON 路由或 Mihomo 分流规则。需要复制到 Remnawave 时，可按提示生成 Mihomo `proxies:` 节点片段；如果有多个 inbound，会逐个确认公网端口、SNI、short-id、public-key。

菜单 7 会优先调用 `sing-box merge -C /etc/sing-box/conf` 读取 sing-box 实际合并后的配置；如果当前环境没有 `sing-box merge`，才回退到直接扫描配置目录。回退模式兼容 fscarmen 生成的配置文件顶部 `// "public_key": "..."` 这类注释行；菜单 7 会同时识别 `auth_user` 分流和按 `inbound` 分流的多端口配置。

菜单 11 会从 GitHub 下载最新版主脚本和分流 helper，默认优先走 GitHub API 以避免 raw 分支缓存。如果你是 `bash <(curl ...)` 临时运行，它会安装到 `/root/nat-singbox-toolkit.sh`；如果你运行的是本地脚本文件，它会备份后原地覆盖。更新完成后需要重新运行脚本才会看到新菜单；新版会提示是否立刻重新打开新版菜单。

菜单 8 会列出 `/etc/sing-box/conf/*.json`，选择文件后先备份单个文件，再用 `nano`/`vi` 编辑；保存退出后自动运行 `sing-box check -C /etc/sing-box/conf`，通过后可选择重启，失败时会提示备份路径并可立即恢复该文件。

生成 Remnawave/Mihomo 片段时，只有“客户端连接地址”和“客户端连接端口”描述的是外部访问入口：NAT 小鸡通常要把端口改成面板映射出来的公网端口。`servername/SNI`、`short-id`、`public-key` 必须与服务端 Reality 配置一致，通常直接回车；`client-fingerprint` 保持已测试值即可。

发布到自己的 GitHub 后，请把脚本里的：

```bash
ROUTE_HELPER_URL="https://github.com/jiwen77/nat-singbox-toolkit/raw/refs/heads/main/apply-singbox-authuser-routes.sh"
```

改成你的真实仓库地址。也可以运行时临时覆盖：

```bash
ROUTE_HELPER_URL=https://github.com/jiwen77/nat-singbox-toolkit/raw/refs/heads/main/apply-singbox-authuser-routes.sh \
  bash <(curl -fsSL https://github.com/jiwen77/nat-singbox-toolkit/raw/refs/heads/main/nat-singbox-toolkit.sh)
```

## 组合方式

本项目不复制第三方脚本代码，而是以“菜单 wrapper”的方式调用上游：

- fscarmen/sing-box：安装 sing-box 底座。
- 本项目 helper：修改多 UUID / auth_user 分流。
- 系统 OpenRC/systemd：管理 SSH SOCKS 落地隧道。

这样便于更新上游脚本，也减少许可证和维护压力。
