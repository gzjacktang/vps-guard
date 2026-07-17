# nftables 防火墙说明

VPS Guard v1 只使用 nftables 作为写入型防火墙后端。基础功能面向普通 VPS 主机，不把服务器当作路由器、网关或 NAT 设备。

## 受管范围

VPS Guard 只创建并替换：

```text
table inet vps_guard
```

持久配置位于 `/etc/nftables.d/vps-guard.nft`，状态位于 `/etc/vps-guard/firewall.conf`。工具只在 `/etc/nftables.conf` 中追加或移除这一条精确标记的 include：

```text
include "/etc/nftables.d/vps-guard.nft" # vps-guard
```

不会执行 `flush ruleset`，不会创建或修改 `FORWARD`、NAT、Docker/Podman/LXC/CNI/Kubernetes 链、VPN 配置或第三方 nftables 表。停用只删除上述自有表、两个受管文件和精确 include 行。

状态文件是所有权凭据。首次启用时，只要发现同名运行时表、受管规则文件或精确 include，却没有有效的 `enabled=1` 状态记录，工具就按归属冲突返回退出码 3；不会猜测该对象属于 VPS Guard，也不会删除或覆盖它。状态目录和文件在正常安装时分别使用 `0700` 和 `0600` 权限。

## 安全基线

规则使用 `inet` 地址族，同一套规则同时作用于 IPv4 和 IPv6：

- input：默认拒绝。
- output：默认允许。
- 允许 `established,related` 已建立或关联连接。
- 允许回环接口 `lo`。
- 允许 IPv4 ICMP 和 IPv6 ICMPv6，避免破坏路径 MTU、邻居发现和基础网络诊断。
- 允许当前 SSH 会话服务端端口以及 `sshd -T` 报告的全部配置端口。
- 允许用户明确配置的基础 TCP/UDP 端口。

规则不创建 forward 链，因此不会接管容器转发或路由流量。不同 nftables 基础链可能同时存在；本工具的 accept 不会删除或覆盖其他表中的规则。

## 当前 SSH 入口保护

启用或更新前，工具合并两个来源：

1. `SSH_CONNECTION` 的第 4 个字段，即当前已登录会话实际连接的服务端端口。
2. `sshd -T` 的全部生效 `port` 值。

两者都经过 1–65535 校验、去重和排序。无法读取 sshd 生效配置或无法解析非空的 `SSH_CONNECTION` 时拒绝应用，不猜测端口。端口迁移期间因此可以同时保留旧配置端口与当前已验证入口；完整两阶段 SSH 迁移由 SSH 专用功能负责。

## CLI

### 查看状态

```bash
sudo vps-guard firewall status
```

无参数状态报告磁盘配置、内核 `inet vps_guard` 表、自有规则和本机监听进程。过滤状态把三个层次明确分开：

```bash
sudo vps-guard firewall status --ports 443 --protocol tcp \
  --direction inbound --family ipv4 --source 198.51.100.0/24 --interface eth0
sudo vps-guard firewall status --ports 443 --protocol tcp --external-confirm reachable
```

第一层只说明 VPS Guard 自有规则允许、拒绝或未放行；其他本机 nftables 表仍可能改变结果。第二层来自 `ss` 的监听与进程信息，读取失败显示“未知”而不是“未监听”。第三层默认“未验证”，因为云安全组、NAT、供应商防火墙和路由不由本机 nftables 决定。`--external-confirm` 只记录用户本次查询提供的 `reachable` 或 `blocked` 证据，不冒充工具自动探测，也不持久保存可能很快过期的结论。

### 启用基线

```bash
sudo vps-guard --dry-run firewall enable --tcp 80,443 --udp 53 --yes
sudo vps-guard firewall enable --tcp 80,443 --udp 53
```

`--tcp` 与 `--udp` 可省略。端口语法接受单端口、逗号列表、范围和混合格式，例如 `80,443,8000-8100`。区间会排序、去重并合并相邻或重叠部分；越界、倒置、空项和歧义输入在任何快照或写入前拒绝。

不传 `--yes` 时会在展示完整摘要和通过语法检查后交互确认。脚本或自动化可以显式使用 `--yes`，但仍会运行预检、快照和语法检查；防火墙变更成功后立即生效，不会自动创建回滚计时器。

启用或更新的最坏后果是规则错误导致 SSH 连接中断、VPS 暂时失联。操作前应确认云控制台、串行控制台或救援模式至少有一种可用；防火墙操作不自动回滚，因此带外恢复入口尤为重要。

### 开放或关闭基础端口

```bash
sudo vps-guard firewall open --ports 80,443 --protocol tcp
sudo vps-guard firewall open --ports 53 --protocol udp
sudo vps-guard firewall close --ports 80 --protocol tcp
```

协议允许 `tcp`、`udp` 或 `both`。重复开放已开放端口、关闭已关闭端口均返回成功的幂等提示，不创建新快照。受保护 SSH 集合独立于额外 TCP 集合，因此基础关闭命令不能移除当前 SSH 入口。

### 高级维度与出站限制

```bash
sudo vps-guard firewall open --ports 8443-8445 --protocol tcp \
  --direction inbound --family ipv4 --source 198.51.100.0/24 --interface eth0
sudo vps-guard firewall open --ports 5353 --protocol udp \
  --direction inbound --family ipv6 --source 2001:db8::/48
sudo vps-guard firewall close --ports 53,80,443 --protocol both \
  --direction outbound --family dual --source all
```

显式指定方向、地址族、来源或接口即进入高级路径。`dual + all` 会展开为 IPv4 与 IPv6 原子规则；指定单一家族 IP/CIDR 时必须明确选择相同家族，避免另一家族被意外解释为全来源。入站使用 `ip/ip6 saddr` 和可选 `iifname`；出站的 `--source` 表示本机发出数据包的源地址，接口使用 `oifname`。接口只做严格名称校验，允许为将来才出现的动态接口预配置。

入站基线默认拒绝，因此入站 `close` 撤销匹配的自有 accept，并支持从区间中拆除部分端口。出站基线默认允许，因此出站 `close` 新增显式 drop，`open` 则撤销该 drop。出站限制位于菜单高级子项，应用前会警告 DNS、APT/HTTPS、NTP、邮件、监控和业务回连可能中断。output 链先保留 `established,related`，所以已有连接可能暂时继续，新连接仍会受限制。

摘要展示规范化端口、重复/重叠折叠和可能仍生效的更宽规则。若关闭时没有匹配的自有放行，操作幂等成功；但只要 `ss` 仍发现服务监听，就会额外警告“服务仍在运行”。

### 停用

```bash
sudo vps-guard firewall disable
```

停用前会明确警告：VPS Guard 不再过滤任何端口，实际开放情况转由其他本机防火墙与上游网络策略决定。重复停用返回幂等成功。

停用的最坏后果是原本被本工具拦截的服务意外暴露到公网。执行前同样应确认带外控制台或救援模式可用，并在新会话中复核实际监听与上游安全组。

## 写入事务

启用、开放、关闭和停用均按以下顺序执行：

1. 验证端口和 3/5/10 分钟回滚窗口。
2. 验证自有状态；同名对象没有有效所有权记录时返回退出码 3。
3. 检查是否已有等待确认的防火墙事务；有则返回退出码 3。
4. 运行只读环境预检；冲突管理器或不可读状态返回退出码 3。
5. 生成完整候选规则并展示摘要。
6. 使用 `nft -c -f` 检查完整事务；已有自有表时，校验输入会先精确删除旧表再声明候选表，但检查模式不会实际修改内核。失败时零写入。
7. 要求用户确认。
8. 创建受管配置快照。
9. 原子替换受管磁盘文件，但暂不重载 live 表。
10. 创建独立于 SSH 会话的 systemd 自动回滚，默认 5 分钟，可选 3 或 10 分钟。
11. 回滚调度成功后才精确重载自有 live 表；失败则立即恢复并保留或取消相应保护任务。
12. 要求从新 SSH 会话验证，再运行 `vps-guard rollback confirm <令牌>` 提交。

应用失败或 systemd 调度失败会立即恢复快照。超时回滚不仅恢复文件，还会重新加载或删除内核中的自有表。存在等待确认的防火墙回滚时拒绝开始第二个事务，避免两个定时任务按不同快照相互覆盖。

## 最低版本兼容

Debian 12 的 nftables 还没有较新版本的 `destroy table` 语法，因此规则文件不使用该命令。通过所有权检查后，工具才用 `nft list table inet vps_guard` 只读判断已登记的自有表是否存在，仅在存在时执行精确的 `nft delete table inet vps_guard`，随后加载候选文件。语法检查使用同样的完整事务，避免已存在的自有表造成虚假的 `File exists`；`nft -c` 本身不执行变更。此流程不会触碰其他表，并兼容当前支持矩阵的最低版本。

持久配置通过 `/etc/nftables.conf` 的精确 include 生效。真实发布验收必须在隔离虚拟机中验证 nftables 服务重载和重启后的规则状态；容器或命令桩测试不能替代内核 Netfilter 验收。

## 验证与恢复

规则应用后不要关闭旧 SSH 会话。先从另一个终端建立新会话并验证业务端口，再确认回滚。外部验证示例：

```bash
nc -4 -vz 服务器地址 443
nc -6 -vz IPv6地址 443
nc -u -vz 服务器地址 53
```

UDP 无法仅凭一次 `nc -u` 结果可靠判断，需使用真实协议（例如 DNS 可用 `dig @服务器地址`）并结合服务端日志。验证还必须检查云安全组、NAT/端口转发和供应商防火墙。若新会话失败，不要确认，等待自动回滚。紧急手工步骤见 [恢复指南](RECOVERY.md)。

## 真实系统发布门禁

Shell 桩测试不替代内核网络验证。发布前须在 Debian 12/13 与受支持 Ubuntu 虚拟机或 VPS 记录：范围、IPv4/IPv6 CIDR、`iifname/oifname` 的 `nft -c` 与真实流量结果；network namespace/veth 的双栈入站；出站 DNS/HTTPS 新连接中断及超时恢复；重启后持久化；TCP/UDP/IPv6 的 `ss -p` 解析；第三方表、容器 FORWARD/NAT 保持不变；第二台主机的 `nc -4/-6` 结果及云网络前提。未完成时只能标记“代码与模拟测试通过，真实 VPS 验证待完成”。

## 参考

- [Debian 12 nftables 手册](https://manpages.debian.org/bookworm/nftables/nft.8.en.html)
- [Netfilter 上游 nftables 手册](https://netfilter.org/projects/nftables/manpage.html)
- [nftables 区间说明](https://wiki.nftables.org/wiki-nftables/index.php/Intervals)
- [nftables inet 地址族](https://wiki.nftables.org/wiki-nftables/index.php/Nftables_families)
- [Debian 12 ss 手册](https://manpages.debian.org/bookworm/iproute2/ss.8.en.html)
