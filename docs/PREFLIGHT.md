# 网络环境预检说明

网络环境预检是在 SSH、防火墙和端口写入功能之前运行的只读保护层。它不替代 Docker、VPN、控制面板或现有防火墙管理器，而是在修改网络配置前集中展示可能导致断网、容器失联或面板无法访问的事实。

## 使用方式

```bash
sudo vps-guard preflight
```

也可以进入主菜单的“状态与诊断 → 网络环境预检”。菜单会展示完整报告，但不会因为发现冲突而退出整个菜单；CLI 会通过退出码供自动化判断。

```bash
sudo vps-guard preflight
case $? in
  0) echo "预检通过" ;;
  3) echo "存在冲突或状态无法确认，禁止写入" ;;
esac
```

## 报告等级

- `[事实]`：命令、服务、进程、接口、监听端口或配置路径提供了直接证据。
- `[待确认]`：检测到了相关环境，但无法仅凭本机状态判断公网入口、上游安全组或业务用途，需要管理员确认。
- `[阻断]`：继续写入可能与另一个防火墙管理器冲突，或关键状态读取失败。CLI 返回退出码 `3`。

“进程正在监听”不代表端口一定能从公网访问；云安全组、供应商防火墙、NAT、反向代理和路由仍可能拦截。反过来，没有发现监听也不代表端口可以安全关闭，例如服务可能尚未启动、按需启动或运行在独立网络命名空间中。

## 检测范围

### 容器

- Docker：命令、`dockerd` 进程和 `docker*`/`br-*` 接口。
- Podman：命令、进程和 `podman*` 接口。
- LXC：`lxc-info`/`lxc-ls`、LXC 进程和 `lxcbr*` 接口。
- 当前系统自身是否运行在 Docker、Podman 或 LXC 容器中。

预检只读取容器状态。VPS Guard 不修改 `FORWARD`、NAT、Docker/Podman/LXC/CNI/Kubernetes 链，也不修改容器网络命名空间。若 legacy iptables 中只有明确的容器链，报告为 `[待确认]` 而不是冲突；只要混入无法归类为容器链的活动规则，就默认阻断。

### VPN

- WireGuard：`wg show`、`wg*` 接口和实际监听端口。
- OpenVPN：命令、进程和关联监听。
- Tailscale：命令、`tailscaled` 进程和 `tailscale*` 接口。

检测到 VPN 后，管理员必须确认隧道接口和实际 UDP/TCP 监听端口需要保留。工具不会编辑 WireGuard、OpenVPN 或 Tailscale 配置，也不会自动猜测或放行端口。

### 控制面板

预检识别宝塔、1Panel、Cockpit、cPanel 和 Plesk 的常见命令、进程、服务或安装路径，并关联 `ss` 可见的监听。面板端口可能被管理员修改，因此报告只把实际监听作为事实，不把常见默认端口当成事实。启用防火墙前必须从面板配置和当前监听两处核对。

### 云代理

预检识别 Amazon SSM Agent、Azure Linux Agent、Google Guest Agent、QEMU Guest Agent、Cloudflare Tunnel 和 Cloudflare WARP 的常见进程。云代理可能承担救援登录、隧道或实例管理；检测结果用于提醒，不会停止、重启或重配代理。

### 防火墙管理器

- UFW 活动：阻断。
- firewalld 运行中：阻断。
- iptables 存在非容器活动规则：阻断。
- UFW、firewalld、iptables 或 nftables 已安装但状态无法读取：失败安全，阻断。
- nftables 已有规则：提醒确认，但不自动判定为冲突。后续 VPS Guard 只管理自己命名的表，绝不清空或覆盖第三方表。

出现阻断时有两条安全路径：继续使用现有管理器；或者先在控制台/救援通道可用的前提下，手动完成迁移或停用，再重新运行预检。v1 不提供 UFW、firewalld 或复杂 iptables 规则的自动迁移。

## 只读保证

预检只调用查询命令：

```text
ps -eo comm=,args=
ip -o link show
ss -lntupH
wg show
systemctl is-active --quiet <服务>
ufw status
firewall-cmd --state
iptables-save
nft list ruleset
```

预检不会调用 `add`、`delete`、`flush`、`enable` 或 `disable`，不会安装软件，不会创建快照、审计日志或 systemd 任务。行为测试会记录所有探测命令，并断言不存在写入型参数。

## 与后续写入功能的关系

防火墙写入模块必须先调用统一门禁 `require_firewall_write_preflight`。只有退出码为 `0` 才能进入快照、自动回滚和规则应用阶段；退出码为 `3` 时默认停止。预检通过不等于变更无风险，写入阶段仍必须创建快照、安排独立自动回滚，并由新 SSH 会话验证后确认。

## 排查误判

如果报告与实际情况不一致，先单独运行上述只读命令确认来源。不要为了让预检通过而直接清空规则。建议保存以下信息后提交 Issue：发行版与版本、预检完整输出、相关命令的脱敏输出、管理器名称，以及预期分类。请删除公网 IP、用户名、密钥、令牌和业务域名等敏感内容。
