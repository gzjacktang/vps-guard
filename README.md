# VPS Guard

VPS Guard 是一个面向 Debian 与 Ubuntu VPS 的中文安全管理工具。项目将统一管理 SSH、nftables、Fail2ban、配置快照和自动回滚；当前已提供只读系统诊断、网络环境冲突预检、快照恢复与 systemd 定时回滚，尚未启用防火墙或 SSH 写入功能。

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

## 直接运行

```bash
git clone https://github.com/gzjacktang/vps-guard.git
cd vps-guard
sudo ./vps-guard.sh status
sudo ./vps-guard.sh preflight
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

- 当前版本只读取状态，不修改 SSH、防火墙或 Fail2ban。
- 预检不会修改 FORWARD、NAT、容器链、VPN 配置或任何第三方 nftables 表；详细说明见 [网络环境预检](docs/PREFLIGHT.md)。
- “进程正在监听”不等于端口可从公网访问；云安全组、NAT 和上游防火墙仍可能拦截。
- 后续高风险操作将统一使用配置快照和独立于 SSH 会话的自动回滚。
- 在未来启用写入功能前，请确保云控制台、串行控制台或救援模式可用。

## 开发检查

```bash
make test
make check
```

`make check` 需要 ShellCheck 与 shfmt；GitHub Actions 会在 Linux/Bash 5 环境运行静态检查和完整行为测试。

详细需求与实施顺序见 [PRD](docs/PRD.md) 和 GitHub Issues。
