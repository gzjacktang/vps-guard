# 兼容性与验证层级

## 正式支持矩阵

| 发行版 | 版本 | amd64 | arm64 |
| --- | --- | --- | --- |
| Debian | 12、13 | 支持 | 支持 |
| Ubuntu | 22.04、24.04、26.04 LTS | 支持 | 支持 |

核心要求 Bash 5.x。普通运行不需要 Python、Node.js 或图形环境。SSH 管理需要 OpenSSH server，回滚需要 systemd，防火墙写入需要 nftables，端口检测需要 iproute2，Fail2ban 功能需要官方 APT 包 `fail2ban`、`python3-systemd` 与 nftables。

Ubuntu 24.04 及更新版本可能使用 `ssh.socket` 和 systemd generator；VPS Guard 会检测 socket activation，并通过 daemon-reload/restart socket 让端口变化生效。Debian/传统 Ubuntu service 模式使用 ssh/sshd reload。真实目标仍必须通过独立新 SSH 会话验证。

## CI 能证明什么

GitHub Actions 的 host job 执行 ShellCheck、shfmt 和全部行为测试。容器 smoke matrix 在 `debian:12-slim`、`debian:13-slim`、`ubuntu:22.04`、`ubuntu:24.04`、`ubuntu:26.04` 中运行行为测试、安装计划、版本命令和实际镜像的只读状态命令。

容器 smoke 只能证明 Bash/用户空间兼容性，不能证明：

- systemd 作为 PID 1 的 timer/service 行为；
- 内核 Netfilter 与 nftables 持久化；
- sshd 的真实监听、认证及新旧端口断连；
- Fail2ban 从 journal 读取真实失败登录并写入 nftables；
- amd64 runner 上的 arm64 原生运行。

因此容器 job 明确命名为 `container-smoke`，不得当作真实 VM 验收证据。

## 真实 VM 发布门禁

首个 v1 Release 必须对同一份合并单文件 artifact 至少完成：

- 一台受支持 Debian 隔离 VM；
- 一台受支持 Ubuntu 隔离 VM；
- 真实 sshd 新旧端口迁移与新会话提交；
- systemd 独立计时器；
- nftables live reload、重启后持久化和第三方规则不受影响；
- Fail2ban sshd jail、封禁与解封；
- 故意不确认造成连接中断后，3 分钟自动回滚恢复旧入口；
- 快速向导成功提交和失败恢复。

证据必须记录待发布单文件的 SHA-256，不记录主机地址、用户名、密钥、日志正文或云账号。当前状态见 [`validation/vm/v1.env`](../validation/vm/v1.env)：`NOT_VERIFIED` 表示代码与模拟测试可以继续，但 Release workflow 必须失败，不能创建正式 Release。

详细执行、脱敏和回填步骤见 [真实 VM 门禁协议](../validation/vm/README.md)。

## 不支持与限制

- 不支持 RHEL/Rocky/Alma/CentOS、Arch、非 Linux、非 systemd 主机或 Bash 4 及更早版本。
- 不管理云安全组、NAT、路由器、容器 FORWARD/NAT、VPN 或第三方 nftables 表。
- 本机监听和规则存在不等于公网可达。
- arm64 单元矩阵不是 arm64 真实机器证据；正式发布仍应在目标架构按风险补充验证。
