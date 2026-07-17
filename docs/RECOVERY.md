# 恢复指南

## 自动回滚仍在等待

不要在旧 SSH 会话中取消回滚。先从另一终端验证新 SSH 连接和所需服务；确认正常后执行：

```bash
sudo vps-guard rollback confirm <令牌>
```

## 查看状态

```bash
sudo vps-guard rollback status <令牌>
sudo vps-guard audit list
```

## 手动恢复快照

先比较，再恢复：

```bash
sudo vps-guard backup diff <快照ID>
sudo vps-guard backup restore <快照ID>
```

恢复会覆盖当前受管配置，并删除“快照时明确不存在、之后新建”的受管文件。操作前应准备云控制台、串行控制台或服务商救援模式。

## SSH 已断开

等待回滚窗口结束后从旧端口重试。如果仍无法连接，进入服务商控制台，检查 `vps-guard rollback status` 与审计日志；不要先清空全部防火墙规则。必要时选择已知快照执行手动恢复。

SSH 端口迁移有两个令牌：`ssh-...` 是迁移令牌，`rb-...` 是自动回滚令牌。旧端口会话不能提交迁移，也不能直接取消 `ssh-firewall` 回滚。新端口登录成功后执行：

```bash
sudo vps-guard ssh confirm <SSH迁移令牌>
```

若只能进入云控制台、串行控制台或救援终端，可使用同样带自动回滚的恢复入口：

```bash
sudo vps-guard ssh reset-port-22 --rollback-minutes 5
sudo vps-guard ssh restore <已知快照ID> --rollback-minutes 5
```

重置到 22 仍需从新的 22 端口 SSH 会话确认；选择性恢复完成后需从新会话验证，再确认输出的普通回滚令牌。不要手工删除 `00-vps-guard-port.conf` 而不同时恢复原 `Port` 指令和防火墙状态。

## 快速安全配置中断

快速向导输出 `wizard-...` 向导令牌和 `rb-...` 自动回滚令牌。不要直接确认 `rb-...`；工具会拒绝这种绕过。先保留旧会话，从新终端验证 SSH、业务端口和 Fail2ban：

```bash
sudo vps-guard wizard status <wizard令牌>
sudo vps-guard firewall status
sudo vps-guard fail2ban status
sudo vps-guard wizard confirm <wizard令牌>
```

如果向导改变了 SSH 端口，最后一条命令必须从目标新端口的 SSH 会话执行。任一关键组件应用失败时，工具会恢复同一份起始快照并重载三个运行时；只在恢复和取消计时任务都成功时才报告立即恢复完成。若新连接失败或状态不确定，不要确认，等待 3/5/10 分钟后重试旧入口。

向导在恢复前会先持久化 `recovering`。即使恢复后写状态失败或进程中断，后续 `wizard confirm` 也只会再次执行幂等恢复并最终标记 `failed`，不会把已恢复的旧配置误报为 `committed`。

超时后 `wizard status` 会结合关联回滚状态显示 `rolled-back`。恢复到向导前没有自有 Fail2ban jail 的状态时，工具仍会重启 Fail2ban，防止已删除的 jail 继续残留在内存中。

SSH 认证加固使用 `hard-...` 事务令牌。新公钥会话无法登录时，不要执行 `ssh harden confirm`，保留旧会话并等待 3/5/10 分钟自动恢复。客户端公钥导入默认 5 分钟自动撤销认证 drop-in 和本工具新增密钥；服务器生成的备用私钥默认 10 分钟清理。可用 `ssh key status` 查看状态、对待确认项执行 `ssh key discard` 立即撤销。通用 SSH 快照不覆盖用户自行维护的 `authorized_keys`，避免恢复配置时意外删除其他管理员密钥。完整排错见 [SSH 密钥设置与可选加固](SSH-HARDENING.md)。

## 防火墙恢复

防火墙变更后无法建立新 SSH 会话时，不要执行 `rollback confirm`，等待 3/5/10 分钟窗口结束。自动回滚会恢复 `/etc/nftables.conf`、自有规则文件和状态文件，并同步重新加载或删除 `table inet vps_guard`。

如果 systemd 任务失败但仍可使用控制台，先查询令牌：

```bash
sudo vps-guard rollback status <令牌>
sudo vps-guard rollback run <令牌>
sudo vps-guard firewall status
```

若日志提示配置事务锁等待超时，systemd 会每 30 秒重试。不要直接删除仍由活动进程持有的锁；应从带外控制台确认并终止卡住的 `vps-guard` 事务进程，再手工执行 `rollback run`。空锁或所属 PID 已退出时，工具会自动清理陈旧锁。

如需手工停用自有运行时表，只删除本工具的表，不要执行 `nft flush ruleset`：

```bash
sudo nft list table inet vps_guard
sudo nft delete table inet vps_guard
```

之后从已知快照恢复持久文件。第三方表、容器链、FORWARD 和 NAT 不属于 VPS Guard 的恢复范围。

高级出站关闭可能中断 DNS、APT/HTTPS、NTP、邮件、监控和业务回连。工具会在重载运行时规则之前安排自动回滚；如果新连接异常，不要确认令牌，等待回滚。已建立连接因连接跟踪可能暂时继续，这不代表新连接未被限制。

## Fail2ban 恢复

应用、停用或选择性恢复 Fail2ban 后，先保持当前 SSH 会话，从另一终端验证公钥登录及 `fail2ban status`，再确认输出的普通回滚令牌。若新会话失败，不要确认，等待自动恢复。

只恢复 VPS Guard 自有 jail，而不覆盖第三方 jail：

```bash
sudo vps-guard fail2ban restore <已知快照ID> --rollback-minutes 5
```

如果 Fail2ban 无法启动，进入服务商控制台查看 `fail2ban-client -t`、`systemctl status fail2ban` 和审计日志。不要删除整个 `/etc/fail2ban`；`fail2ban disable` 也只删除 `/etc/fail2ban/jail.d/vps-guard.local`。详见 [Fail2ban SSH 防护](FAIL2BAN.md)。
