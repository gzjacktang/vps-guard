# VPS Guard CLI

所有系统状态或配置命令均要求 root。全局 `--dry-run` 必须放在子命令之前；dry-run 只显示计划，不创建快照、状态文件或 systemd 任务。

## 网络环境预检

```text
vps-guard preflight
```

只读检测 Docker、Podman、LXC、WireGuard、OpenVPN、Tailscale、常见控制面板、云代理、相关接口与监听端口，并检查 UFW、firewalld、iptables 和 nftables 管理状态。报告将结论区分为“事实”“待确认”和“阻断”。详细检测依据和安全边界见 [网络环境预检说明](PREFLIGHT.md)。

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
| 3 | 环境冲突或关键防火墙状态无法确认，默认禁止写入 |
| 4 | 权限不足 |
| 5 | 系统未在正式支持矩阵中 |
