# 真实 Debian/Ubuntu VM 门禁协议

本目录只存脱敏结果，不存 SSH 地址、IP、用户名、主机名、密钥、云实例 ID、命令历史、备份或日志。执行者必须确认测试对象是可销毁隔离 VM，并已有云控制台、串行控制台或救援模式。

## 准备

1. 从候选 commit 运行 `make check` 和 `make single`。
2. 记录 `sha256sum dist/vps-guard-<版本>-single.sh`。
3. 把完全相同的单文件复制到 Debian 与 Ubuntu VM。
4. 从外部控制机执行重复 SSH 检查时必须使用 `ControlMaster=yes`、独立 `ControlPath` 和 `ControlPersist`，不要短时间反复建立新连接。
5. 每次改变 SSH 端口前确认带外控制台可用，并保留旧会话。

## 每台 VM 的必检项

```text
[ ] artifact_sha256 与候选完全一致
[ ] OS/版本/架构在支持矩阵
[ ] vps-guard status 与 preflight
[ ] sshd -t；旧、新端口过渡；新端口真实公钥会话提交；旧端口关闭
[ ] systemd-run timer 在 SSH 会话结束后仍存在并执行
[ ] nftables 自有表 reload 成功，重启后持久，第三方表/容器链未改变
[ ] Fail2ban sshd jail 使用 systemd backend 与 nftables action，真实失败登录可封禁并解封
[ ] 故意不确认并断开连接，3 分钟后旧 SSH 入口自动恢复
[ ] 快速向导标准方案成功提交
[ ] 注入一个关键组件失败，完整快照恢复且没有误报 committed
```

建议为新 SSH 端口建立第二条 ControlMaster，而不是复用旧端口 socket。验证公网可达性必须从 VM 外部进行，本机 `ss` 只证明监听。

## 结果回填

每台 VM 的脱敏结果分别写入 `debian.env` 和 `ubuntu.env`：只记录发行版、版本、架构、artifact SHA-256、sshd/systemd/nftables/Fail2ban/断连回滚/向导的 PASS/FAIL 和 UTC 日期。两台均 PASS 且 hash 相同后，维护者才可把 `validation/vm/v1.env` 改为：

```text
status=PASS
artifact_sha256=<64位小写SHA-256>
debian_result=PASS
ubuntu_result=PASS
```

变更必须由另一名审查者核对原始私有测试记录；原始日志留在受控环境，不提交仓库。`scripts/check-vm-gate.sh` 和 Release workflow 会同时校验状态与候选单文件 hash。
