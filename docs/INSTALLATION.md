# 安装、手动更新与卸载

## 信任边界

VPS Guard 不提供 `curl | bash`，也不在后台检查、下载或执行更新。`vps-guard update check` 只通过 HTTPS 读取官方 GitHub Release 元数据；真正更新必须由管理员下载源码包和 `SHA256SUMS`、核对校验和、审阅内容，再从本地解压目录运行安装器。

SHA-256 能发现传输损坏或文件与 Release 清单不一致，但不是数字签名，也不能防止 GitHub 发布账号本身被攻破。高安全环境应固定已审阅的 commit/tag，并保留自己的可信哈希记录。

## 首次安装

先查看目标、权限和依赖，不写文件：

```bash
./install.sh --dry-run
```

计划会列出源码版本、版本目录、固定 launcher、目录/脚本/模块权限，以及 Bash、OpenSSH、systemd、nftables、`ss`、`diff` 和可选 Fail2ban 的检测结果。安装器不会自动运行 APT。

确认后安装：

```bash
sudo ./install.sh
sudo vps-guard version
sudo vps-guard status
```

布局如下：

```text
/usr/local/lib/vps-guard/
├── current -> releases/1.0.0
├── releases/1.0.0/
└── program-backups/
/usr/local/sbin/vps-guard   # 固定 launcher，不是指向模块入口的软链
```

launcher 执行 `current/vps-guard.sh`，因此入口查找模块时使用真实版本目录。systemd 自动回滚记录的是不可变版本目录中的真实脚本；更新会保留旧版本，避免已调度任务因入口切换而失效。

## 手动更新

只检查元数据：

```bash
vps-guard update check
```

发现不同版本后，在浏览器中下载同一 Release 的源码包和 `SHA256SUMS`，放在同一目录并验证：

```bash
sha256sum -c SHA256SUMS
tar -xzf vps-guard-<版本>.tar.gz
cd vps-guard-<版本>
./install.sh --update --dry-run
sudo ./install.sh --update
sudo vps-guard version
```

`--update` 只读取当前本地目录，不联网。它先把当前程序复制到 root-only 的 `program-backups/<UTC>-<旧版本>`，再构建和健康检查暂存版本，最后切换 `current`。备份、暂存或健康检查失败时不会切换入口。自动化可以加 `--yes`，这代表调用者已经在外部完成显式审批，不会改变下载与校验边界。

若需要回退程序代码，先确认没有运行中的安装器，再把 `current` 切回已知版本目录；程序回退不会恢复 `/etc` 配置。配置回退必须使用 `backup restore` 或对应模块的选择性恢复，二者不要混淆。

## 卸载

只预览：

```bash
sudo vps-guard --dry-run uninstall
```

默认卸载：

```bash
sudo vps-guard uninstall
```

默认只删除 `/usr/local/lib/vps-guard` 和 `/usr/local/sbin/vps-guard`，明确保留：

- `/etc/vps-guard` 以及 SSH、nftables、Fail2ban 的现行受管配置；
- `/var/lib/vps-guard` 中的快照、事务和回滚状态；
- `/var/log/vps-guard/audit.log`。

这意味着卸载程序不会停用当前防护。若要改变系统安全配置，应先使用 `firewall disable`、`fail2ban disable` 或受保护的 SSH 恢复流程。

额外清理快照、事务数据和审计日志：

```bash
sudo vps-guard uninstall --purge-data
```

此模式仍保留 `/etc` 与 live 防护，只会多删除快照、事务和审计日志。无论是否使用此选项，交互模式都只要求一次确认；非交互自动化可使用：

```bash
sudo vps-guard uninstall --yes --purge-data
```

存在 `pending`、`running`、`schedule-failed` 或 `failed` 自动回滚时，卸载返回退出码 3。不要手工删除程序绕过检查，否则断连后的 systemd 恢复可能找不到执行文件。

## 安装器参数

```text
./install.sh [--update] [--dry-run] [--yes]
```

- `--update`：从当前本地源码更新已安装版本；首次安装禁止使用。
- `--dry-run`：只显示计划，不要求 root，不写文件。
- `--yes`：跳过本地安装/更新的交互确认；不触发联网下载。
- 未知参数退出 2；权限不足退出 4；Bash/运行环境不支持退出 5；异常安装布局退出 3。
