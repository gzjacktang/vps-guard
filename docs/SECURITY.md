# 安全模型

## 所有权边界

VPS Guard 只备份和恢复登记为“受管路径”的配置。快照中的绝对路径必须通过路径穿越检查；快照时不存在的受管文件会记录为 `missing`，因此回滚能够删除操作后新建的该文件。工具拒绝按 `missing` 记录递归删除目录。

## 快照完整性

- 数据目录默认为 `/var/lib/vps-guard`，目录权限为 `0700`。
- 每个普通文件记录 SHA-256 与原权限。
- 恢复前验证全部文件，任一校验失败均不开始覆盖。
- 文件先在目标目录准备，再逐个替换；提交中途失败时恢复已经替换的旧文件。
- 默认只保留最近 10 份快照，可设置为 1–100。

## 自动回滚

回滚由 `systemd-run` 创建临时单元，不依赖发起操作的 SSH 会话存活。状态包括等待确认、已确认、执行中、已回滚、失败和调度失败。确认操作先停止 systemd 单元，再写入已确认状态，避免“显示成功但任务仍运行”。

## 审计与敏感数据

审计日志默认为 `/var/log/vps-guard/audit.log`，目录 `0700`、文件 `0600`。记录 root UID，并在通过 sudo 执行时记录经过格式校验的 `SUDO_USER`。日志不得记录密码、私钥、用户自由输入的标签或认证日志正文；调用模块只能提交动作标识、结果、快照/回滚标识和预定义原因。

## 第三方网络保护

任何防火墙写入前都必须通过只读环境预检。UFW、firewalld、非容器 iptables 规则或无法读取的管理状态会返回退出码 3 并默认阻断。已有 nftables 表、容器链、VPN 和控制面板只被检测和提醒，VPS Guard 不接管其生命周期。

VPS Guard 不修改 `FORWARD`、NAT、Docker/Podman/LXC/CNI/Kubernetes 链、VPN 配置或第三方 nftables 表。检测规则、命令清单、误判处理和自动化退出码详见 [网络环境预检说明](PREFLIGHT.md)。

## 防火墙事务

防火墙只拥有 `table inet vps_guard`、`/etc/nftables.d/vps-guard.nft`、`/etc/vps-guard/firewall.conf` 和 `/etc/nftables.conf` 中一条精确标记的 include。候选规则必须先通过 `nft -c`；确认后才创建快照并应用。应用失败、回滚调度失败或超时都会恢复磁盘配置并同步恢复内核中的自有表。

`/etc/vps-guard/firewall.conf` 是防火墙所有权记录。没有有效状态文件时，即使发现的对象名称恰好是 `inet vps_guard`，也一律视为第三方或归属不明并返回冲突码 3，禁止接管。

启用时同时保留当前 `SSH_CONNECTION` 服务端端口和 `sshd -T` 配置端口。存在未确认的防火墙事务时禁止叠加第二个事务。详细流程见 [nftables 防火墙说明](FIREWALL.md)。

## SSH 两阶段事务

SSH 迁移把 `SSH_CONNECTION` 当作已验证会话证据，把 `sshd -T` 当作磁盘配置的生效结果；两者用途不同，不能互相替代。迁移阶段先启动 systemd 回滚，再同时写入旧、新端口并同步防火墙。`sshd -t`、生效端口、sshd 监听、服务 reload 或防火墙任一检查失败都会立即恢复快照。

只有目标新端口会话才能通过 `ssh confirm` 关闭旧端口。关联的 `ssh-firewall` 回滚令牌拒绝普通 `rollback confirm`，避免在旧会话或本机监听检查后绕过证明步骤。SSH 迁移或选择性恢复等待确认时，所有普通防火墙写入也被阻断，避免不同快照的计时器交叉覆盖。超时恢复文件后还会同步 reload sshd 与自有 nftables 运行时。详细状态、受管文件和恢复入口见 [SSH 端口两阶段迁移](SSH.md)。
