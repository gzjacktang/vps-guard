# 快速安全配置

## 设计目标

快速入口用于首次部署，不把所有高级参数堆在一个页面。它只有四个选择：

1. 标准防护（推荐）：SSH 两阶段端口迁移（可保持不变）、nftables 入站安全基线、Fail2ban 标准策略。
2. 仅防火墙：保持 SSH 与 Fail2ban 不变，只启用或更新自有 nftables 基线。
3. 仅 Fail2ban：保持 SSH 和防火墙配置不变，只应用标准 SSH 封禁策略。
4. 查看方案详情。

密钥生成、禁用密码、root 登录策略、来源 IP/CIDR、接口和出站限制不在快速问题中；它们仍属于 SSH、防火墙或 Fail2ban 子菜单。进入子菜单再返回时，向导保留已经填写的方案和端口，不要求从头输入。高级 SSH 子菜单的写入必须先在新会话完成对应确认；防火墙与 Fail2ban 写入则立即生效。只有之后的快速应用实际迁移 SSH 端口时，才创建一个涵盖完整起点的快照和一个回滚任务。

## 三步流程

第一步选择方案。标准方案只询问 SSH 新端口；留空表示保持当前生效端口。仅防火墙和仅 Fail2ban 不允许顺带迁移 SSH，避免方案含义模糊。

第二步确认业务端口。工具读取 `ss -H -lntup`，排除当前 SSH 端口和仅绑定回环地址的服务，然后把剩余 TCP/UDP 监听端口作为建议值。它们只是“本机正在监听”的事实，不证明云安全组、NAT 或上游防火墙允许公网访问。读取失败时不能把未知误当作空列表，应手工输入需要保留的业务端口。

第三步查看统一差异和风险摘要。摘要同时列出 SSH 当前、过渡及目标端口，防火墙业务端口，Fail2ban 策略和不参与本方案的组件。应用前必须确认云控制台、串行控制台或服务商救援模式可用。

## 单一事务

向导不会串联 `ssh migrate`、`firewall enable` 和 `fail2ban apply`，因为它们各自拥有独立事务。向导直接复用各模块的严格校验、候选渲染和受管安装接口，并统一负责：

- 在任何写入前完成全部候选校验；
- 创建一份覆盖 SSH、nftables 和 Fail2ban 受管路径的完整快照；
- 创建一个独立于当前 SSH 会话的 systemd 回滚任务；
- 在新端口迁移时同步使用旧、新端口过渡集合；
- 任一关键步骤失败时恢复起始快照和相关运行时；
- 成功验证后通过一次 `wizard confirm` 提交。

因此，一次向导应用只应看到一个快照 ID、一个 `rb-...` 回滚令牌和一个 `wizard-...` 向导令牌。不要手工叠加第二个防火墙或 SSH 写入事务。

## 命令示例

先预览标准方案：

```bash
sudo vps-guard --dry-run wizard apply \
  --plan standard --ssh-port 2222 --tcp 80,443 --udp 53 --yes
```

正式应用：

```bash
sudo vps-guard wizard apply \
  --plan standard --ssh-port 2222 --tcp 80,443 --udp 53
```

保持 SSH 不变、只配置防火墙：

```bash
sudo vps-guard wizard apply --plan firewall --tcp 80,443 --udp 53
```

只配置已安装的 Fail2ban：

```bash
sudo vps-guard wizard apply --plan fail2ban
```

Fail2ban 安装不属于可由文件快照撤销的事务。缺少软件包时，向导只显示官方 APT 安装计划并退出；应先在 Fail2ban 子菜单单独安装，再重新运行向导。

## 验证与提交

查看组合事务状态：

```bash
sudo vps-guard wizard status <wizard令牌>
```

如果改变了 SSH 端口，保留旧会话，从另一个终端登录目标端口，再在新会话执行：

```bash
sudo vps-guard wizard confirm <wizard令牌>
```

确认会把 sshd、防火墙和 Fail2ban 从旧、新端口过渡集合收敛为目标新端口，验证监听后取消自动回滚。旧端口会话以及普通 `rollback confirm <rb令牌>` 都不能绕过这项证明。

若保持 SSH 不变，向导会在应用后立即完成；仍应验证业务端口及 Fail2ban 状态，但无需执行 `wizard confirm`，也不会存在自动回滚任务。

状态 `committing` 表示目标配置仍在位、正在取消自动回滚；存储或 systemd 暂时失败时可重试 `wizard confirm`。状态 `recovering` 表示提交失败后正在恢复起始快照，此状态只允许继续幂等恢复，绝不会补记为已提交；恢复完成后状态为 `failed`，需要重新运行向导。

## 失败与真实系统门禁

自动测试使用隔离文件树和命令桩覆盖三种方案、子菜单往返、取消、候选失败、部分应用失败、超时恢复和成功提交。它们不能证明真实网络栈行为。

发布前仍必须在至少一台 Debian 和一台 Ubuntu 隔离虚拟机验证：

- systemd 临时计时任务在 SSH 断开后仍执行；
- sshd 旧、新端口过渡和新会话证明；
- nftables `inet` 双栈规则的真实加载与恢复；
- Fail2ban systemd backend 和 nftables 动作的真实启停；
- 标准向导部分失败及真实断连后的完整快照恢复。

这些项目是发布门禁，不应以本机模拟测试替代。完整恢复步骤见 [恢复指南](RECOVERY.md)。
