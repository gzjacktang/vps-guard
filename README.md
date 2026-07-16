# VPS Guard

VPS Guard 是一个面向 Debian 与 Ubuntu VPS 的中文安全管理工具。项目将统一管理 SSH、nftables、Fail2ban、配置快照和自动回滚；当前已提供只读系统诊断、网络环境冲突预检、SSH 端口两阶段迁移、nftables 安全基线、基础端口管理、快照恢复与 systemd 定时回滚，SSH 密钥加固与 Fail2ban 管理仍在后续切片中。

## 当前能力

- 识别 Debian 12/13、Ubuntu 22.04/24.04/26.04 LTS。
- 识别 `amd64` 与 `arm64`。
- 检查 root 权限、核心依赖、SSH 服务和监听端口。
- 缺少依赖时仅展示官方 APT 安装建议，不自动安装或升级。
- 提供中文分层菜单、`status` 子命令和 `--dry-run` 标记。
- 所有诊断均为只读操作。
- 创建、列出、比较和恢复带校验和的配置快照。
- 使用独立 systemd 临时单元执行 3、5 或 10 分钟自动回滚。
- 查询回滚状态，并在验证成功后幂等确认取消。
- 只读识别容器、VPN、控制面板、云代理、接口、监听端口和冲突防火墙管理器。
- UFW、firewalld、非容器 iptables 规则或不可读状态默认返回冲突退出码并阻止后续写入。
- 启用双栈 `inet vps_guard` 安全基线：入站默认拒绝、出站默认允许，保留当前 SSH、连接跟踪、回环和 ICMP/ICMPv6。
- 通过单端口或逗号列表幂等开放/关闭基础 TCP/UDP 端口，所有写入默认带 5 分钟自动回滚。
- 停用只删除 VPS Guard 自有表和受管配置，不清空第三方 nftables、FORWARD、NAT 或容器链。
- SSH 端口迁移期间同时保留旧、新入口；只有新端口的真实 SSH 会话可以一次性提交并关闭旧端口。
- 提供带独立回滚的重置到 22 和选择性 SSH 快照恢复路径。

## 直接运行

```bash
git clone https://github.com/gzjacktang/vps-guard.git
cd vps-guard
sudo ./vps-guard.sh status
sudo ./vps-guard.sh preflight
sudo ./vps-guard.sh --dry-run firewall enable --tcp 80,443 --udp 53 --yes
sudo ./vps-guard.sh --dry-run ssh migrate --port 2222 --yes
```

进入中文菜单：

```bash
sudo ./vps-guard.sh
```

明确标记只读预览模式：

```bash
sudo ./vps-guard.sh --dry-run status
```

## 快照与自动回滚

```bash
sudo ./vps-guard.sh backup create --label before-change
sudo ./vps-guard.sh backup list
sudo ./vps-guard.sh backup diff <快照ID>
sudo ./vps-guard.sh backup restore <快照ID> --yes

sudo ./vps-guard.sh rollback start <快照ID> --minutes 5
sudo ./vps-guard.sh rollback status <回滚令牌>
sudo ./vps-guard.sh rollback confirm <回滚令牌>
```

`rollback start` 创建独立于当前 SSH 会话的 systemd 临时任务。只有验证新连接和服务正常后才应执行 `rollback confirm`。详细参数和故障恢复见 [CLI 文档](docs/CLI.md)、[安全模型](docs/SECURITY.md) 与 [恢复指南](docs/RECOVERY.md)。

## 安装

先查看安装计划，不写入文件：

```bash
./install.sh --dry-run
```

确认后安装：

```bash
sudo ./install.sh
sudo vps-guard status
```

程序安装到 `/usr/local/lib/vps-guard`，命令入口为 `/usr/local/sbin/vps-guard`。实际安装要求 Bash 5.x；普通使用者不需要 Python、Node.js 或图形界面依赖。

## 退出码

| 退出码 | 含义 |
| --- | --- |
| `0` | 成功或用户安全取消 |
| `1` | 运行失败或系统信息不可读 |
| `2` | 命令或参数错误 |
| `3` | 网络环境冲突或关键状态无法确认 |
| `4` | 权限不足 |
| `5` | 系统或运行环境不受支持 |

## 安全边界

- `status` 与 `preflight` 始终只读；只有明确的 `firewall`、`ssh` 写入子命令会修改受管范围。
- 防火墙只管理 `table inet vps_guard`；SSH 端口迁移只管理标准 sshd 配置范围和自有 drop-in。SSH 密钥加固与 Fail2ban 尚未交付。
- 预检不会修改 FORWARD、NAT、容器链、VPN 配置或任何第三方 nftables 表；详细说明见 [网络环境预检](docs/PREFLIGHT.md)。
- “进程正在监听”不等于端口可从公网访问；云安全组、NAT 和上游防火墙仍可能拦截。
- 高风险 SSH 与防火墙操作统一使用配置快照和独立于 SSH 会话的自动回滚。
- 写入前请确保云控制台、串行控制台或救援模式可用。SSH 迁移细节见 [SSH 端口两阶段迁移](docs/SSH.md)。

## 开发检查

```bash
make test
make check
```

`make check` 需要 ShellCheck 与 shfmt；GitHub Actions 会在 Linux/Bash 5 环境运行静态检查和完整行为测试。

详细需求与实施顺序见 [PRD](docs/PRD.md) 和 GitHub Issues。
