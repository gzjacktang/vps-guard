# VPS Guard

VPS Guard 是一个面向 Debian 与 Ubuntu VPS 的中文安全管理工具。项目最终将统一管理 SSH、nftables、Fail2ban、快照和自动回滚；当前首个实施切片提供只读系统诊断与安装骨架，不会修改防火墙或 SSH 配置。

## 当前能力

- 识别 Debian 12/13、Ubuntu 22.04/24.04/26.04 LTS。
- 识别 `amd64` 与 `arm64`。
- 检查 root 权限、核心依赖、SSH 服务和监听端口。
- 缺少依赖时仅展示官方 APT 安装建议，不自动安装或升级。
- 提供中文分层菜单、`status` 子命令和 `--dry-run` 标记。
- 所有诊断均为只读操作。

## 直接运行

```bash
git clone https://github.com/gzjacktang/vps-guard.git
cd vps-guard
sudo ./vps-guard.sh status
```

进入中文菜单：

```bash
sudo ./vps-guard.sh
```

明确标记只读预览模式：

```bash
sudo ./vps-guard.sh --dry-run status
```

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
| `4` | 权限不足 |
| `5` | 系统或运行环境不受支持 |

## 安全边界

- 当前版本只读取状态，不修改 SSH、防火墙或 Fail2ban。
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
