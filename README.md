# VPS Guard

VPS Guard 是一个面向 Debian 与 Ubuntu VPS 的中文安全管理工具。项目统一管理 SSH、nftables、Fail2ban、配置快照和自动回滚；当前已提供只读系统诊断、网络环境冲突预检、SSH 两阶段迁移与认证加固、nftables 安全基线、Fail2ban SSH 防护、快照恢复与 systemd 定时回滚。

## 当前能力

- 识别 Debian 12/13、Ubuntu 22.04/24.04/26.04 LTS。
- 识别 `amd64` 与 `arm64`。
- 检查 root 权限、核心依赖、SSH 服务和监听端口。
- 缺少依赖时仅展示官方 APT 安装建议，不自动安装或升级。
- 提供中文分层菜单、`status` 子命令和 `--dry-run` 标记。
- 提供压缩为四个入口的快速安全配置：标准防护、仅防火墙、仅 Fail2ban、查看详情。
- 所有诊断均为只读操作。
- 创建、列出、比较和恢复带校验和的配置快照。
- 使用独立 systemd 临时单元执行 3、5 或 10 分钟自动回滚。
- 查询回滚状态，并在验证成功后幂等确认取消。
- 只读识别容器、VPN、控制面板、云代理、接口、监听端口和冲突防火墙管理器。
- UFW、firewalld、非容器 iptables 规则或不可读状态默认返回冲突退出码并阻止后续写入。
- 启用双栈 `inet vps_guard` 安全基线：入站默认拒绝、出站默认允许，保留当前 SSH、连接跟踪、回环和 ICMP/ICMPv6。
- 通过单端口或逗号列表幂等开放/关闭基础 TCP/UDP 端口；防火墙和 Fail2ban 变更会立即生效，不会自动回滚。
- 支持端口范围与混合表达式，以及方向、协议、IPv4/IPv6、来源 CIDR 和接口限定；高级出站限制带强警告。
- 三层端口状态分别报告 VPS Guard 规则、本机监听进程和外部可达性证据，不把监听误称为公网开放。
- 停用只删除 VPS Guard 自有表和受管配置，不清空第三方 nftables、FORWARD、NAT 或容器链。
- SSH 端口迁移期间同时保留旧、新入口；只有新端口的真实 SSH 会话可以一次性提交并关闭旧端口。
- 检查 sshd 实际生效认证配置，安全导入公钥，提供客户端 Ed25519 引导及带自动清理的服务器端加密密钥备用流程。
- 禁用密码前必须由目标用户的新公钥会话证明指定密钥可用；root、空密码、认证重试和等待时间均可选并受自动回滚保护。
- 提供带独立回滚的重置到 22 和选择性 SSH 快照恢复路径。
- 使用官方 APT 包安装 Fail2ban，并以 systemd 日志后端和 nftables multiport 动作保护当前 SSH 端口。
- 提供宽松、标准、严格、渐进和自定义策略；标准策略为 10 分钟内 5 次失败封禁 1 小时。
- 在明确确认后白名单当前管理 IP，支持查看封禁、解封 IPv4/IPv6、选择性恢复与只停用自有 jail。
- 标准快速流程只询问 SSH 新端口与业务端口；仅在实际迁移 SSH 端口时，SSH、防火墙、Fail2ban 才作为一个完整快照、一个计时器和一次确认共同提交。
- 使用版本化程序目录和固定 `vps-guard` launcher；手动更新检查不下载或执行远程代码，更新前备份现有程序。
- 默认卸载只移除程序并保留系统配置、快照和日志；数据清理沿用同一次确认，不会反复要求输入固定短语。
- Release 构建生成版本化源码包、合并单文件版和 `SHA256SUMS`，真实 Debian/Ubuntu VM 证据未完成时发布工作流硬失败。

## 直接运行

克隆后即可通过 `sudo ./vps-guard.sh` 使用全部功能，无需安装。以下按推荐顺序演示核心能力，`--dry-run` 确保只预览不写入，去掉即可真实执行。

```bash
git clone https://github.com/gzjacktang/vps-guard.git
cd vps-guard
```

**1. 查看系统状态** — 只读展示发行版、架构、SSH 监听端口、防火墙状态、Fail2ban 防护等全貌：

```bash
sudo ./vps-guard.sh status
```

**2. 网络环境预检** — 只读扫描容器、VPN、控制面板、冲突防火墙（UFW/firewalld），判断当前环境是否适合 VPS Guard 接管：

```bash
sudo ./vps-guard.sh preflight
```

**3. 防火墙安全基线** — 启用入站默认拒绝 + 出站默认允许，仅放行指定 TCP/UDP 端口。保留 SSH、回环、ICMP 和已有连接：

```bash
sudo ./vps-guard.sh --dry-run firewall enable --tcp 80,443 --udp 53 --yes
```

**4. SSH 端口迁移** — 将 SSH 从默认 22 迁移到指定端口，迁移期间新旧端口同时保留，只有新端口成功登录后才能确认关闭旧端口：

```bash
sudo ./vps-guard.sh --dry-run ssh migrate --port 2222 --yes
```

**5. Fail2ban 防护** — 安装并启用 SSH 暴力破解防护，预设 `standard` 为 10 分钟内 5 次失败封禁 1 小时：

```bash
sudo ./vps-guard.sh --dry-run fail2ban apply --preset standard --no-whitelist-current-ip --yes
```

**6. 快速安全向导（推荐）** — 将 SSH 迁移、防火墙基线和 Fail2ban 合并为一次原子操作：一份快照、一个回滚计时器、一次确认：

```bash
sudo ./vps-guard.sh --dry-run wizard apply --plan standard --ssh-port 2222 --tcp 80,443 --udp 53 --yes
```

去掉 `--dry-run` 即可真实执行。只有 SSH 端口迁移（包括向导中实际更换 SSH 端口）默认配置 5 分钟自动回滚；防火墙和 Fail2ban 操作不会创建计时器。新端口登录成功后，必须执行命令输出的 `ssh confirm` 或 `wizard confirm`，否则计时结束仍会恢复旧 SSH 配置。

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

快速向导的关联回滚不能用普通 `rollback confirm` 绕过；应按输出使用 `wizard confirm`。完整三步流程见 [快速安全配置](docs/QUICK-START.md)。

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

检查版本与官方 Release 元数据：

```bash
vps-guard version
vps-guard update check
```

更新不会自动下载执行。下载并核对 Release 的 `SHA256SUMS` 后，从本地解压目录执行：

```bash
./install.sh --update --dry-run
sudo ./install.sh --update
```

默认保留安全配置、快照和日志的卸载命令为 `sudo vps-guard uninstall`；额外清理数据需要 `--purge-data` 和第二次固定短语确认。完整说明见 [安装、手动更新与卸载](docs/INSTALLATION.md)。

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

- `status` 与 `preflight` 始终只读；只有明确的 `firewall`、`ssh`、`fail2ban` 写入子命令会修改受管范围。
- 防火墙只管理 `table inet vps_guard`；SSH 只管理标准配置范围、自有 drop-in 及明确选择的目标 `authorized_keys`；Fail2ban 只管理 `/etc/fail2ban/jail.d/vps-guard.local`。
- 预检不会修改 FORWARD、NAT、容器链、VPN 配置或任何第三方 nftables 表；详细说明见 [网络环境预检](docs/PREFLIGHT.md)。
- “进程正在监听”不等于端口可从公网访问；云安全组、NAT 和上游防火墙仍可能拦截。
- 高风险 SSH 与防火墙操作统一使用配置快照和独立于 SSH 会话的自动回滚。
- 写入前请确保云控制台、串行控制台或救援模式可用。SSH 迁移细节见 [SSH 端口两阶段迁移](docs/SSH.md)。
- SSH 密钥证明、服务器备用私钥和认证参数说明见 [SSH 密钥设置与可选加固](docs/SSH-HARDENING.md)。
- Fail2ban 的预设、白名单、nftables 共存和恢复细节见 [Fail2ban SSH 防护](docs/FAIL2BAN.md)。
- 快速组合事务、监听端口建议与子菜单边界见 [快速安全配置](docs/QUICK-START.md)。

## 开发检查

```bash
make test
make check
```

`make check` 需要 ShellCheck 与 shfmt；GitHub Actions 会在 Linux/Bash 5 环境运行静态检查和完整行为测试。

```bash
make single
make release
```

发布构建、敏感信息扫描、支持系统容器 smoke 和真实 VM 门禁见 [v1 发布流程](docs/RELEASE.md) 与 [兼容性说明](docs/COMPATIBILITY.md)。当前 `validation/vm/v1.env` 为 `NOT_VERIFIED` 时只能生成候选产物，不能创建正式 v1 Release。

详细需求与实施顺序见 [PRD](docs/PRD.md) 和 GitHub Issues。
