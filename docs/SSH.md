# SSH 端口两阶段迁移

VPS Guard 不会直接把旧 SSH 端口替换成新端口。端口修改采用两阶段事务：第一阶段同时保留旧、新入口；第二阶段必须由新端口上的真实 SSH 会话提交，之后才关闭旧入口。

## 前置条件与受管范围

- 必须先启用 VPS Guard nftables 防火墙；迁移会同步更新 `table inet vps_guard` 中独立的 SSH 端口集合。
- 普通迁移必须从可解析的 SSH 会话执行。工具读取 `SSH_CONNECTION` 第 4 个字段作为当前会话的服务端端口，并确认它属于 `sshd -T` 报告的生效端口。`sudo` 默认清理该变量时，工具只沿当前命令的 Linux `/proc` 父进程链恢复原 SSH 会话信息；不会扫描其他会话，也不要求使用 `sudo -E`。两种证据都不存在时拒绝迁移。
- 新端口必须是 1–65535 的单个端口，不能已经出现在 sshd 生效配置中，也不能被其他 TCP 服务监听。
- 只支持 Debian/Ubuntu 标准的 `Include /etc/ssh/sshd_config.d/*.conf` 配置入口。未检测到该入口时返回冲突码 3，不猜测非标准 Include。
- 自有配置为 `/etc/ssh/sshd_config.d/00-vps-guard-port.conf`，所有权状态为 `/etc/vps-guard/ssh.conf`。

首次迁移时，工具会把 `/etc/ssh/sshd_config` 和标准 `sshd_config.d/*.conf` 中已有的全局 `Port` 指令注释为 `vps-guard disabled original port`，然后由自有 drop-in 同时声明旧端口和新端口。这样第二阶段只需把自有文件缩减为新端口。所有原文件和防火墙配置都在修改前进入同一个快照。

## CLI

### 预览或开始迁移

```bash
sudo vps-guard --dry-run ssh migrate --port 2222 --rollback-minutes 5 --yes
sudo vps-guard ssh migrate --port 2222 --rollback-minutes 5
```

允许的回滚窗口为 3、5 或 10 分钟，默认 5 分钟。`--yes` 只跳过交互确认，不跳过端口检查、冲突预检、`sshd -t`、快照或自动回滚。

迁移顺序：

1. 校验当前 SSH 会话、sshd 生效端口、新端口占用和标准 Include。
2. 验证 VPS Guard 防火墙所有权，不允许与未确认的防火墙、SSH 迁移或 SSH 恢复事务重叠；SSH 事务等待确认时，普通防火墙写入同样被阻断。
3. 显示旧端口、迁移期间端口、提交后端口和最坏后果。
4. 检查当前 `sshd -t`，创建包含 SSH 与自有防火墙的完整快照。
5. 在写配置前启动独立的 systemd 自动回滚。
6. 写入旧端口与新端口，重新执行 `sshd -t`，并用 `sshd -T` 验证生效端口集合。
7. 先让防火墙放行新端口，再更新 SSH 运行时。传统 service 模式会平滑 reload `ssh`/`sshd`；检测到 Ubuntu socket activation 时执行 `systemctl daemon-reload` 后 restart `ssh.socket`，让生成器重新读取端口。
8. 使用 `ss -ltnp` 确认 sshd 确实监听旧、新端口；这只是附加检查，不能替代第二阶段的新会话证明。

### 从新会话提交

第一阶段会返回 SSH 迁移令牌，例如 `ssh-...`。保留旧会话，在另一终端登录：

```bash
ssh -p 2222 用户@服务器
sudo vps-guard ssh confirm <SSH迁移令牌>
```

确认命令再次解析该会话的 `SSH_CONNECTION`。只有服务端端口与目标新端口完全一致时才会继续；服务器本机监听成功、旧端口会话或直接执行 `rollback confirm` 均不能提交 SSH 迁移。

提交会把 sshd 与防火墙的 SSH 集合缩减为新端口，平滑重载并确认新端口正在监听、旧端口不再由 sshd 监听，然后取消自动回滚。重复确认已提交令牌返回幂等成功。

```bash
sudo vps-guard ssh status <SSH迁移令牌>
```

状态同时显示迁移状态、旧/新端口、关联的自动回滚令牌及其状态。

## 重置到 22

```bash
sudo vps-guard ssh reset-port-22 --rollback-minutes 5
```

重置使用相同的两阶段事务，不是直接覆盖。它明确警告标准端口可能暴露给公网扫描。为了支持救援场景，此入口可以在没有 `SSH_CONNECTION` 的云控制台、串行控制台或救援终端启动，但仍需从端口 22 的新 SSH 会话提交；若已经只使用 22，则返回幂等成功。

## 从快照恢复 SSH

```bash
sudo vps-guard --dry-run ssh restore <快照ID> --yes
sudo vps-guard ssh restore <快照ID> --rollback-minutes 5
```

恢复视图只选择目标快照中的以下范围：

- `/etc/ssh/sshd_config` 与 `/etc/ssh/sshd_config.d/*.conf`
- `/etc/vps-guard/ssh.conf`
- 与该 SSH 快照匹配的 VPS Guard nftables 规则文件和防火墙状态

它不会恢复 Fail2ban、日志、密钥、整个 `/etc/nftables.conf` 或第三方配置。若目标快照启用了自有防火墙，只会在当前 `/etc/nftables.conf` 中补回精确的 VPS Guard include；若目标未启用则只移除该精确行。恢复前还会创建“操作前”快照并安排新的 `ssh-restore` 自动回滚；从新会话验证后使用输出中的普通 `rollback confirm <令牌>` 提交。

## 失败与回滚

语法检查、生效端口、监听检查、防火墙应用或服务 reload 任一步失败，工具都会立即尝试恢复事务前快照，并同步 reload sshd 与自有 nftables 表。连接中断时不要直接删除防火墙规则，也不要确认回滚；等待 3/5/10 分钟后从旧端口重试。

最坏后果是 SSH 连接中断、VPS 暂时失联。自动回滚不能代替带外恢复入口，操作前必须确认云控制台、串行控制台或救援模式可用。

## 已知限制与发布门禁

- v1 不自动改写非标准 Include 路径或显式带端口的复杂 `ListenAddress` 设计；生效端口或真实监听与计划不一致时失败并恢复。
- `sshd -T` 与本机 LISTEN 只能证明本机配置，不能证明云安全组、NAT、路由和公网路径可达。
- 正式发布前必须在至少一个 Debian 和一个 Ubuntu 隔离虚拟机中完成真实旧会话保留、新端口登录、提交关闭旧端口、reload、systemd 超时回滚和重启后持久性验收。命令桩或容器测试不能替代真实 SSH 会话。

## 参考

- [Debian 12 sshd_config 手册](https://manpages.debian.org/bookworm/openssh-server/sshd_config.5.en.html)
- [OpenBSD 上游 sshd_config 手册](https://man.openbsd.org/sshd_config)
- [Ubuntu 24.04 OpenSSH socket activation 说明](https://discourse.ubuntu.com/t/ubuntu-24-04-lts-noble-numbat-release-notes/39890)
