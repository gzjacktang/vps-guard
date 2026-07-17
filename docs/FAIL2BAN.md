# Fail2ban SSH 防护

VPS Guard v1 只管理 SSH jail，目标是在不接管第三方配置的前提下完成安装、策略配置、封禁查询、解封和可回滚恢复。自有文件固定为 `/etc/fail2ban/jail.d/vps-guard.local`。

## 安装边界

```bash
sudo vps-guard fail2ban install
```

工具先显示将执行的命令，再单独确认：

```text
apt-get update
apt-get install -y fail2ban python3-systemd nftables
```

只使用 Debian/Ubuntu 官方 APT 软件源，不添加 PPA 或第三方仓库，不执行系统整体升级。Ubuntu 若未启用提供该包的官方组件，安装会明确失败；工具不会擅自修改软件源。安装失败不会创建或修改 jail。`fail2ban apply` 也绝不隐式安装，便于管理员把包管理和安全策略写入拆成两个可审计步骤。

## 策略预设

| 策略 | 统计窗口 | 失败次数 | 首次封禁 | 渐进封禁 |
| --- | ---: | ---: | ---: | --- |
| `lenient` | 10 分钟 | 10 | 10 分钟 | 否 |
| `standard` | 10 分钟 | 5 | 1 小时 | 否 |
| `strict` | 10 分钟 | 3 | 12 小时 | 否 |
| `progressive` | 10 分钟 | 5 | 1 小时 | 是，最长 7 天 |

v1 不允许永久封禁。自定义策略边界为：`findtime` 60–86400 秒、`maxretry` 1–20、`bantime` 60–604800 秒、最长封禁不小于首次封禁且不超过 2592000 秒。渐进封禁固定 factor 为 1。

示例：

```bash
sudo vps-guard fail2ban apply --preset standard
sudo vps-guard fail2ban apply --preset progressive --no-whitelist-current-ip
sudo vps-guard fail2ban apply --preset custom \
  --findtime 900 --maxretry 4 --bantime 7200 \
  --increment true --max-bantime 604800
```

写入前会显示当前自有文件到候选文件的统一差异，以及端口、统计窗口、次数、封禁时长、渐进上限、白名单、日志后端和封禁动作的最终摘要。`--yes` 只跳过最后的应用确认，不代表同意把当前 IP 加白；自动化必须明确使用 `--whitelist-current-ip` 或 `--no-whitelist-current-ip`。

## 当前管理 IP 与白名单

交互运行时，工具从当前 `SSH_CONNECTION` 检测客户端 IP，并单独询问是否加入 `ignoreip`。默认回答为否。只有单个、语法有效的 IPv4/IPv6 地址会被采用；无法识别当前 SSH 会话时，`--whitelist-current-ip` 会拒绝继续，而不会猜测出口 IP 或整个网段。

`--ignore-ip` 支持逗号或空格分隔的地址/CIDR。工具始终保留本机回环 `127.0.0.1/8 ::1`。白名单会绕过该 jail 的封禁，请只加入稳定且可信的管理来源。

## 运行方式与 nftables 共存

自有 jail 使用：

- `filter = sshd`
- `backend = systemd`，直接读取 systemd journal，不设置发行版相关的 `logpath`
- `banaction = nftables[type=multiport]`，一次保护当前全部 SSH 端口
- `usedns = no` 与 `ignoreself = true`

Fail2ban 的 nftables action 管理它自己的集合和规则；VPS Guard 防火墙仍只拥有 `table inet vps_guard`。工具不会 flush ruleset、FORWARD、NAT、容器链或第三方表。SSH 两阶段迁移时，Fail2ban 会先保护旧、新端口；迁移提交后再收敛到最终端口。联动 reload 失败会阻止 SSH 事务继续提交。

## 查询与解封

```bash
sudo vps-guard fail2ban status
sudo vps-guard fail2ban banned
sudo vps-guard fail2ban unban 198.51.100.8
sudo vps-guard fail2ban unban 2001:db8::8
```

`unban` 只操作 `sshd` jail。地址未被封禁时返回幂等成功；地址语法无效时返回参数错误。操作不会修改持久配置。

## 自动回滚、停用与选择性恢复

应用前先校验临时候选配置，再创建快照和 3/5/10 分钟 systemd 回滚。候选文件会以 `0600` 在目标目录内暂存并通过同文件系统 rename 原子提交；同名文件缺少所有权标记、root 所有权或安全权限时拒绝接管。live 配置写入后再次执行测试、重启服务、ping 服务端并查询 sshd jail；任一步失败都会尝试立即恢复，只有恢复完整成功才取消计时任务，否则保留独立回滚作为第二道保护。

应用成功后保持旧会话，从另一个终端验证 SSH 登录和状态，再执行输出提示中的：

```bash
sudo vps-guard rollback confirm <回滚令牌>
```

停用只删除自有文件：

```bash
sudo vps-guard fail2ban disable
```

它不会卸载包或删除第三方 jail。从已知快照选择性恢复时，也只处理自有文件，并给恢复操作本身再加一层回滚：

```bash
sudo vps-guard fail2ban restore <快照ID>
```

## 限制与真实系统发布门禁

Shell 行为测试用 stub 覆盖预设、参数拒绝、白名单确认、安装失败、状态、IPv4/IPv6 解封、停用和选择性恢复；它不能证明内核、journal 与发行版包的真实联动。正式发布前仍必须在干净虚拟机/VPS 完成以下验证，并记录系统版本和结果：

1. Debian 12、Debian 13、Ubuntu 22.04 LTS、24.04 LTS；Ubuntu 26.04 LTS 在正式镜像与包可用后验证。
2. 安装后 `fail2ban-client -t`、服务启动、systemd journal SSH 失败记录和 sshd jail 计数一致。
3. IPv4 与 IPv6 真实失败登录触发 nftables 集合封禁，解封后恢复连接。
4. 已存在 `table inet vps_guard`、容器/VPN 和第三方 jail 时没有被覆盖。
5. SSH 端口迁移的过渡、提交与超时回滚阶段，Fail2ban 端口始终与 sshd 可达端口一致。

未完成这些真实系统门禁时，应标为“代码与模拟测试通过，真实 VPS 验证待完成”，不能声称相应发行版已经生产验证。

设计依据：[Fail2ban 官方 jail.conf](https://github.com/fail2ban/fail2ban/blob/master/config/jail.conf)、[官方 nftables action](https://github.com/fail2ban/fail2ban/blob/master/config/action.d/nftables.conf)、[Debian jail.conf(5)](https://manpages.debian.org/bookworm/fail2ban/jail.conf.5.en.html) 与 [fail2ban-client(1)](https://manpages.debian.org/bookworm/fail2ban/fail2ban-client.1.en.html)。
