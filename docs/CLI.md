# VPS Guard CLI

所有系统状态或配置命令均要求 root。全局 `--dry-run` 必须放在子命令之前；dry-run 只显示计划，不创建快照、状态文件或 systemd 任务。

## 快速安全配置

```text
vps-guard wizard details
vps-guard wizard apply --plan standard [--ssh-port keep|端口] [--tcp 端口表达式] [--udp 端口表达式] [--rollback-minutes 3|5|10] [--yes]
vps-guard wizard apply --plan firewall [--tcp 端口表达式] [--udp 端口表达式] [--rollback-minutes 3|5|10] [--yes]
vps-guard wizard apply --plan fail2ban [--rollback-minutes 3|5|10] [--yes]
vps-guard wizard status <向导令牌>
vps-guard wizard confirm <向导令牌>
```

菜单入口只列标准防护、仅防火墙、仅 Fail2ban 和查看详情。标准流程只收集 SSH 新端口（留空保持）及 TCP/UDP 业务端口；菜单会把非回环监听端口作为可编辑建议，并排除当前 SSH 端口。密钥、禁用密码、root 策略、来源限制及出站限制仍在对应高级子菜单。

向导先完成所有候选校验，再显示 SSH、防火墙和 Fail2ban 的统一差异、最坏后果及带外恢复提醒。确认后只建立一份完整快照和一个 systemd 自动回滚任务。改变 SSH 端口时，只有目标新端口会话能执行 `wizard confirm`；普通 `rollback confirm` 会被拒绝。详见 [快速安全配置](QUICK-START.md)。

## 网络环境预检

```text
vps-guard preflight
```

只读检测 Docker、Podman、LXC、WireGuard、OpenVPN、Tailscale、常见控制面板、云代理、相关接口与监听端口，并检查 UFW、firewalld、iptables 和 nftables 管理状态。报告将结论区分为“事实”“待确认”和“阻断”。详细检测依据和安全边界见 [网络环境预检说明](PREFLIGHT.md)。

## nftables 防火墙

```text
vps-guard firewall status
vps-guard firewall enable [--tcp 端口列表] [--udp 端口列表] [--rollback-minutes 3|5|10] [--yes]
vps-guard firewall open --ports 端口表达式 --protocol tcp|udp|both [--direction inbound|outbound] [--family ipv4|ipv6|dual] [--source all|IP|CIDR] [--interface 接口] [--rollback-minutes 3|5|10] [--yes]
vps-guard firewall close --ports 端口表达式 --protocol tcp|udp|both [--direction inbound|outbound] [--family ipv4|ipv6|dual] [--source all|IP|CIDR] [--interface 接口] [--rollback-minutes 3|5|10] [--yes]
vps-guard firewall disable [--rollback-minutes 3|5|10] [--yes]
vps-guard firewall status --ports 端口表达式 --protocol tcp|udp|both [--direction inbound|outbound] [--family ipv4|ipv6|dual] [--source all|IP|CIDR] [--interface 接口] [--external-confirm reachable|blocked]
```

端口表达式支持单值、逗号列表、范围和混合格式。未指定高级维度时保持入站、双栈、所有来源兼容行为；显式维度进入高级路径。入站关闭撤销受管放行，出站关闭新增显式 drop，并给出 DNS/APT 等强警告。所有写入先做冲突预检、规则摘要、语法检查和快照，并在 live reload 前创建默认 5 分钟回滚。过滤状态分别报告自有规则、本机监听进程和用户提供的外部验证证据。完整说明见 [nftables 防火墙说明](FIREWALL.md)。

## SSH 端口迁移

```text
vps-guard ssh migrate --port 端口 [--rollback-minutes 3|5|10] [--yes]
vps-guard ssh confirm <SSH迁移令牌>
vps-guard ssh status <SSH迁移令牌>
vps-guard ssh reset-port-22 [--rollback-minutes 3|5|10] [--yes]
vps-guard ssh restore <快照ID> [--rollback-minutes 3|5|10] [--yes]
```

`migrate` 同时保留旧、新端口并同步 VPS Guard 防火墙；只有从目标新端口建立的 SSH 会话才能执行一次性 `ssh confirm`。底层回滚令牌不能绕过该验证直接取消。`reset-port-22` 使用同一事务，且可从带外控制台进入恢复流程。`restore` 只选择 SSH 与匹配的自有防火墙配置，并创建新的回滚保护。完整流程、限制和真实虚拟机发布门禁见 [SSH 端口两阶段迁移](SSH.md)。

## SSH 密钥与可选加固

```text
vps-guard ssh inspect --user 用户
vps-guard ssh key guide --user 用户
vps-guard ssh key import --user 用户 --file 公钥文件 [--yes]
vps-guard ssh key generate-server --user 用户 [--yes]
vps-guard ssh key confirm|status|discard <密钥令牌>
vps-guard ssh harden apply --user 用户 [--proof 密钥令牌] [加固选项] [--rollback-minutes 3|5|10] [--yes]
vps-guard ssh harden confirm|status <加固令牌>
```

禁用密码必须提供目标用户已验证的密钥 proof，并从另一个新公钥会话提交加固。客户端公钥导入未确认时 5 分钟自动撤销；服务器端生成只允许 TTY 交互口令，私钥 10 分钟自动清理。参数、安全证明、恢复与发布门禁详见 [SSH 密钥设置与可选加固](SSH-HARDENING.md)。

## Fail2ban SSH 防护

```text
vps-guard fail2ban install [--yes]
vps-guard fail2ban apply --preset lenient|standard|strict|progressive|custom [策略参数] [--ignore-ip 地址] [--whitelist-current-ip|--no-whitelist-current-ip] [--rollback-minutes 3|5|10] [--yes]
vps-guard fail2ban status
vps-guard fail2ban banned
vps-guard fail2ban unban <IPv4|IPv6>
vps-guard fail2ban disable [--rollback-minutes 3|5|10] [--yes]
vps-guard fail2ban restore <快照ID> [--rollback-minutes 3|5|10] [--yes]
```

安装是独立操作，只使用 Debian/Ubuntu 官方 APT 包；`apply` 不会隐式安装。自定义策略必须指定 `--findtime`、`--maxretry`、`--bantime`，可另设 `--increment true|false` 与 `--max-bantime`。写入前显示最终参数并校验候选配置，写入后启动默认 5 分钟回滚。完整参数边界与恢复步骤见 [Fail2ban SSH 防护](FAIL2BAN.md)。

## 快照

```text
vps-guard backup create [--label 标签]
vps-guard backup list
vps-guard backup diff <快照ID>
vps-guard backup restore <快照ID> [--yes]
vps-guard backup retention [1-100]
```

- `create`：备份受管文件及受管目录中的普通文件，记录 SHA-256、原权限、时间和标签。
- `list`：列出快照 ID、标签和文件数量。
- `diff`：报告已更改、缺失或在快照后新增的受管配置。
- `restore`：完整校验后恢复；没有 `--yes` 时要求交互确认。
- `retention`：查看或修改保留数量，默认 10 份。

## 自动回滚

```text
vps-guard rollback start <快照ID> [--minutes 3|5|10]
vps-guard rollback status <令牌>
vps-guard rollback confirm <令牌>
vps-guard rollback run <令牌>
```

默认窗口为 5 分钟。`run` 是 systemd 定时任务使用的内部公开入口；重复运行或重复确认均是幂等操作。

SSH 迁移、SSH 加固和快速向导拥有受管确认语义，其底层回滚令牌不能直接确认，必须使用对应的 `ssh confirm`、`ssh harden confirm` 或 `wizard confirm`。

## 审计

```text
vps-guard audit list
```

显示最近 100 条操作记录。日志包含 UTC 时间、UID、动作、结果和非敏感摘要。

## 退出码

| 代码 | 含义 |
| --- | --- |
| 0 | 成功、已安全取消或幂等操作已经完成 |
| 1 | 文件、校验、调度或恢复失败 |
| 2 | 参数或标识符错误 |
| 3 | 环境冲突，或关键 SSH/防火墙状态无法确认，默认禁止写入 |
| 4 | 权限不足 |
| 5 | 系统未在正式支持矩阵中 |
