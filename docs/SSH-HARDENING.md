# SSH 密钥设置与可选加固

VPS Guard 的目标不是“写完配置就认为安全”，而是证明目标用户确实能从一个新的 SSH 会话使用指定公钥登录，再允许关闭密码入口。公钥导入、服务器端备用生成和认证加固均可通过中文 SSH 子菜单或同一套 CLI 使用。

## 1. 查看实际生效配置

```bash
sudo vps-guard ssh inspect --user alice
```

工具调用 `sshd -T -C user=alice,host=localhost,addr=127.0.0.1`，展示 OpenSSH 解析后的实际值，而不是只搜索静态文件：

- `PasswordAuthentication` 与 `KbdInteractiveAuthentication`
- `PermitRootLogin` 与 `PermitEmptyPasswords`
- `MaxAuthTries` 与 `LoginGraceTime`
- `AuthorizedKeysFile`、`AuthorizedKeysCommand`、`AuthenticationMethods`
- `ExposeAuthInfo`

报告会明确标出密码登录、键盘交互、root 直接登录、空密码和异常重试/等待设置。`Match` 条件可能因来源地址或主机名不同而产生其他结果；v1 使用固定上下文做管理前检查，真实目标会话仍是最终发布验收的一部分。

## 2. 推荐：在客户端生成 Ed25519 密钥

```bash
sudo vps-guard ssh key guide --user alice
```

推荐在自己的电脑执行：

```bash
ssh-keygen -t ed25519 -a 100 -f ~/.ssh/id_ed25519_vps_guard
ssh-copy-id -i ~/.ssh/id_ed25519_vps_guard.pub -p 2222 alice@服务器
```

私钥始终留在客户端。若希望 VPS Guard 校验、去重、修正权限并建立后续禁用密码所需的 proof，只把 `.pub` 文件传到服务器，再执行：

```bash
sudo vps-guard ssh key import --user alice --file /临时路径/id_ed25519_vps_guard.pub
```

导入规则：

- 目标用户必须由系统账户数据库解析到固定 UID、GID 和绝对 home；不存在、异常或符号链接 home 默认拒绝。
- v1 只自动管理目标用户 home 内实际生效的 `.ssh/authorized_keys`。`AuthorizedKeysCommand` 非 `none`、自定义共享绝对路径等复杂配置只诊断并拒绝自动写入。
- 输入必须只有一条无前置 options 的 OpenSSH 公钥，长度不超过 8 KiB，并通过 `ssh-keygen` 校验。
- 使用 SHA-256 指纹判断重复；同一密钥重复导入返回幂等成功，不追加重复行。
- `.ssh` 设置为 `0700`，`authorized_keys` 设置为 `0600`；已有路径必须归目标 UID 所有，符号链接、非普通文件、硬链接或异常属主默认拒绝。
- 密钥文件的创建、临时文件和原子替换全部经 `runuser` 降权到目标用户执行，避免 root 在用户可写目录中跟随竞态路径。终端、状态摘要和审计日志只显示指纹，不显示公钥正文，更不会接触已有私钥。

导入返回 `key-...` 令牌。保留旧会话，在新终端使用该私钥登录目标用户，然后执行：

```bash
sudo vps-guard ssh key confirm <key令牌>
```

导入会临时启用 `ExposeAuthInfo` 与 `PubkeyAuthentication`，并立即安排 5 分钟自动撤销。确认成功才提交这项配置；未确认、主动 `discard` 或后续写入/调度失败时，会恢复导入前的自有 drop-in，并删除本工具新增的公钥。待确认期间拒绝叠加防火墙、端口迁移、另一项密钥导入或 SSH 加固事务。

## 3. 新密钥会话如何被证明

VPS Guard 在自有早序 drop-in 中启用：

```text
ExposeAuthInfo yes
PubkeyAuthentication yes
```

OpenSSH 会为每个新会话创建临时认证信息文件，并通过 `SSH_USER_AUTH` 指向它。确认操作只接受同时满足以下条件的会话：

1. `sudo` 的登录用户与目标用户相同；
2. `SSH_CONNECTION` 与开始导入/加固时的连接不同；
3. `SSH_USER_AUTH` 明确记录 `publickey` 认证；
4. 文件中的真实公钥经 `ssh-keygen` 计算后，与待验证 key proof 的 SHA-256 指纹一致。

`sudo` 默认清理环境变量时，工具只沿本次命令的 Linux `/proc` 父进程链恢复 `SSH_CONNECTION` 和 `SSH_USER_AUTH` 路径，不扫描其他登录会话。仅有 sshd 监听、本机 shell、旧密码会话或不同公钥都不能生成有效 proof。

这项 proof 的信任边界是“防止管理员误操作导致自己被锁在门外”，不是把已经拥有 `root`/完整 `sudo` 权限的恶意用户隔离在外。OpenSSH 创建的认证信息临时文件可由该登录用户读取；拥有管理员权限的人本来就能修改 sshd、进程环境或 VPS Guard 状态，因此不能把它当成对抗管理员伪造的安全边界。

OpenSSH 对该机制的定义见 [Debian sshd_config(5)](https://manpages.debian.org/trixie/openssh-server/sshd_config.5.en.html) 和 [OpenBSD sshd_config(5)](https://man.openbsd.org/sshd_config)。

## 4. 服务器端生成：仅作备用流程

当服务商没有密钥注入入口、客户端也暂时无法生成时，可选择：

```bash
sudo vps-guard ssh key generate-server --user alice
```

这是明确警告的备用流程：

- 必须在真实交互式 TTY 运行；工具不接受命令行口令或环境变量口令。
- `ssh-keygen` 直接读取并复核口令，命令不使用 `-N "$口令"`，因此口令不会进入脚本变量、进程参数或审计日志。
- 生成 Ed25519 密钥并用空口令解密测试反向确认私钥已加密；发现空口令会立即删除。
- 私钥暂存在目标用户 `.ssh/vps-guard-export-key-.../id_ed25519`，权限 `0600`；只输出路径和 `scp` 命令，绝不显示正文。
- systemd 在 10 分钟后自动执行 `ssh key discard`，删除本工具新增的公钥与服务器私钥；验证成功也会立即删除服务器副本并取消清理任务。
- 密钥先在 root 专用临时目录完成生成和加密验证，再以目标用户权限交付到 `.ssh`；交付、权限设置或调度任一步失败都会清理两处材料并恢复认证配置。

取回后在客户端执行：

```bash
chmod 600 ./id_ed25519
ssh -i ./id_ed25519 -p 2222 alice@服务器
sudo vps-guard ssh key confirm <key令牌>
```

如果放弃待确认密钥，可主动执行：

```bash
sudo vps-guard ssh key discard <key令牌>
```

已验证的密钥不会被 `discard` 静默删除，避免误锁；需要撤销时应人工复核 `authorized_keys`。密钥生成参数和加密文件说明见 [OpenBSD ssh-keygen(1)](https://man.openbsd.org/ssh-keygen)。

## 5. 可选加固参数

```bash
sudo vps-guard --dry-run ssh harden apply \
  --user alice \
  --proof key-... \
  --password-auth no \
  --root-login prohibit-password \
  --empty-passwords no \
  --max-auth-tries 3 \
  --login-grace-time 30 \
  --rollback-minutes 5 \
  --yes
```

| 参数 | 可选值 | 说明 |
| --- | --- | --- |
| `--password-auth` | `keep`、`yes`、`no` | 选择 `no` 必须提供同一目标用户已验证的 key proof；同时写入 `KbdInteractiveAuthentication no`，避免 PAM 键盘交互继续接收密码。若实际 `AuthenticationMethods` 不是 `any` 或单独 `publickey`，则拒绝操作，避免 `publickey,password` 等组合认证被锁死。 |
| `--root-login` | `keep`、`yes`、`prohibit-password`、`no` | 推荐 `prohibit-password` 或在已有可 sudo 非 root 用户时选择 `no`。不能以 root 作为确认用户并同时禁止 root。 |
| `--empty-passwords` | `keep`、`yes`、`no` | 推荐 `no`。 |
| `--max-auth-tries` | `keep` 或 `1-10` | 推荐 3；过低会增加合法用户误触发失败的概率。 |
| `--login-grace-time` | `keep` 或 `10-120` 秒 | 推荐 30；v1 不允许无限等待或过短值。 |

`keep` 表示保留当前 `sshd -T -C` 的实际值。应用前显示每一项 `当前 -> 目标` 差异；所有值写入 `/etc/ssh/sshd_config.d/01-vps-guard-hardening.conf`，随后运行 `sshd -t`、再次读取实际生效值并平滑重载。

## 6. 加固两阶段事务

任何认证方式变更都执行以下流程：

1. 通过全局配置事务锁原子预留写入窗口，并拒绝与未提交的 SSH 密钥、SSH 端口、SSH 加固或受管防火墙事务重叠。
2. 创建操作前快照。
3. 在写配置前启动 3、5 或 10 分钟 systemd 自动回滚，默认 5 分钟。
4. 写配置、语法校验、实际值校验并 reload sshd。
5. 返回 `hard-...` 令牌；旧会话必须保留。
6. 从目标用户的另一个新公钥会话执行：

```bash
sudo vps-guard ssh harden confirm <hard令牌>
```

确认与定时器共用同一回滚锁，并在锁内复查状态，只能有一方获胜。普通 `rollback confirm` 不能绕过新的公钥会话证明。超时会恢复操作前 SSH 配置并 reload sshd。

## 7. 状态、恢复与排错

```bash
sudo vps-guard ssh key status <key令牌>
sudo vps-guard ssh harden status <hard令牌>
sudo vps-guard ssh inspect --user alice
```

如果新密钥无法登录：

- 不要禁用密码，也不要确认加固事务；保留旧会话。
- 检查目标 home、`.ssh` 和 `authorized_keys` 是否被其他账户或自动化再次改写。
- 检查云控制台、串行控制台或救援模式是否可用。
- 已开始加固时等待自动回滚，或从带外控制台查询 `rollback status`。
- 可使用 `ssh restore <快照ID>` 恢复 SSH 配置；用户 `authorized_keys` 不属于通用 SSH 配置快照，避免恢复快照时覆盖用户自行维护的密钥。

## 8. 发布门禁与已知限制

自动测试使用临时文件系统和命令替身，不能替代真实 OpenSSH、PAM、systemd 与新网络连接。Release 前必须在至少一台真实 Debian 和一台真实 Ubuntu 隔离虚拟机验证：

- 客户端 Ed25519 导入、目标用户新会话和 `SSH_USER_AUTH` 指纹证明；
- 客户端导入未确认时的 5 分钟自动撤销，以及复杂 `AuthorizedKeysCommand`/组合 `AuthenticationMethods` 拒绝路径；
- 服务器端带口令生成、`scp` 取回、确认删除和 10 分钟自动清理；
- 禁用密码后公钥登录成功，密码与 keyboard-interactive 登录失败；
- root 策略、重试次数、等待时间的实际生效值；
- 成功确认取消回滚，以及不确认/断连后的真实超时恢复。

v1 不自动改写复杂 `AuthorizedKeysCommand`、共享密钥文件、证书 CA、非标准 home 密钥路径或任意 `Match` 架构；这些环境只报告并默认拒绝自动写入。
