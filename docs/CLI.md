# VPS Guard CLI

所有系统状态或配置命令均要求 root。全局 `--dry-run` 必须放在子命令之前；dry-run 只显示计划，不创建快照、状态文件或 systemd 任务。

## 网络环境预检

```text
vps-guard preflight
```

只读检测 Docker、Podman、LXC、WireGuard、OpenVPN、Tailscale、常见控制面板、云代理、相关接口与监听端口，并检查 UFW、firewalld、iptables 和 nftables 管理状态。报告将结论区分为“事实”“待确认”和“阻断”。详细检测依据和安全边界见 [网络环境预检说明](PREFLIGHT.md)。

## nftables 防火墙

```text
vps-guard firewall status
vps-guard firewall enable [--tcp 端口列表] [--udp 端口列表] [--rollback-minutes 3|5|10] [--yes]
vps-guard firewall open --ports 端口列表 --protocol tcp|udp|both [--rollback-minutes 3|5|10] [--yes]
vps-guard firewall close --ports 端口列表 --protocol tcp|udp|both [--rollback-minutes 3|5|10] [--yes]
vps-guard firewall disable [--rollback-minutes 3|5|10] [--yes]
```

基础端口只支持单值和逗号列表。所有写入先做冲突预检、规则摘要、语法检查和快照，并默认创建 5 分钟回滚。应用后必须从新 SSH 会话验证，再执行 `rollback confirm <令牌>`。完整规则、安全边界、兼容策略和恢复流程见 [nftables 防火墙说明](FIREWALL.md)。

## SSH 端口迁移

```text
vps-guard ssh migrate --port 端口 [--rollback-minutes 3|5|10] [--yes]
vps-guard ssh confirm <SSH迁移令牌>
vps-guard ssh status <SSH迁移令牌>
vps-guard ssh reset-port-22 [--rollback-minutes 3|5|10] [--yes]
vps-guard ssh restore <快照ID> [--rollback-minutes 3|5|10] [--yes]
```

`migrate` 同时保留旧、新端口并同步 VPS Guard 防火墙；只有从目标新端口建立的 SSH 会话才能执行一次性 `ssh confirm`。底层回滚令牌不能绕过该验证直接取消。`reset-port-22` 使用同一事务，且可从带外控制台进入恢复流程。`restore` 只选择 SSH 与匹配的自有防火墙配置，并创建新的回滚保护。完整流程、限制和真实虚拟机发布门禁见 [SSH 端口两阶段迁移](SSH.md)。

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
