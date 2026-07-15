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

## 防火墙恢复

防火墙变更后无法建立新 SSH 会话时，不要执行 `rollback confirm`，等待 3/5/10 分钟窗口结束。自动回滚会恢复 `/etc/nftables.conf`、自有规则文件和状态文件，并同步重新加载或删除 `table inet vps_guard`。

如果 systemd 任务失败但仍可使用控制台，先查询令牌：

```bash
sudo vps-guard rollback status <令牌>
sudo vps-guard rollback run <令牌>
sudo vps-guard firewall status
```

如需手工停用自有运行时表，只删除本工具的表，不要执行 `nft flush ruleset`：

```bash
sudo nft list table inet vps_guard
sudo nft delete table inet vps_guard
```

之后从已知快照恢复持久文件。第三方表、容器链、FORWARD 和 NAT 不属于 VPS Guard 的恢复范围。
