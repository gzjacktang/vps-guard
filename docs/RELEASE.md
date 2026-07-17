# v1 发布流程

## 产物

`make release` 从根目录 `VERSION` 生成：

```text
dist/vps-guard-<版本>.tar.gz
dist/vps-guard-<版本>-single.sh
dist/SHA256SUMS
```

源码包使用 `git archive` 和版本化顶层目录；合并单文件按入口的模块顺序内联全部 `lib/*.sh`，只有一个 shebang，不在运行时读取 `lib/`。`SHA256SUMS` 只覆盖前两个发布物。

构建会执行 Bash 语法检查、敏感内容扫描、归档绝对路径/`..`/链接/特殊文件检查。扫描拒绝私钥头、常见 GitHub/AWS token、日志、私钥文件名和运行期 `authorized_keys`。测试和文档中的 IP 只能使用 RFC 5737/RFC 3849 示例地址。

## 发布顺序

1. 合并所有目标 Issue，确保工作树干净，`make check` 全通过。
2. 构建候选单文件并记录 SHA-256。
3. 在 Debian 与 Ubuntu 隔离 VM 对同一 SHA-256 完成全部门禁。
4. 将脱敏结果写入 `validation/vm/`，把 `v1.env` 更新为两端 `PASS` 和对应 artifact hash，单独复审。
5. 创建与 `VERSION` 完全一致的 tag，例如 `v1.0.0`。
6. Release workflow 再次运行质量检查、构建和校验；若 VM 状态或 artifact hash 不匹配则硬失败。
7. 只有全部门禁通过，workflow 才使用最小 `contents: write` 权限创建 GitHub Release。

在 VM 证据仍为 `NOT_VERIFIED` 时，不得创建或绕过 v1 tag。当前仓库可生成候选产物，但这不等于已经发布。

## 本地验证

```bash
make check
make sensitive
make release
cd dist
sha256sum -c SHA256SUMS
../scripts/check-vm-gate.sh
```

最后一条在真实 VM 证据未完成时预期失败；这是发布保护，不是构建故障。

## 版本一致性

- `VERSION` 是源码版本唯一来源。
- tag 必须是 `v$(cat VERSION)`。
- 安装目录、源码包名、单文件名和单文件内嵌版本都由该文件生成。
- 更新检查发现不同版本只提示，不自动判断或执行升级/降级。
