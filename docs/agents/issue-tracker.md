# Issue tracker：GitHub

本仓库的需求、PRD 和实施任务均存放在 GitHub Issues，使用 `gh` CLI 读取和维护。

## 约定

- 创建 Issue：使用 `gh issue create`。
- 读取 Issue：读取正文、评论和标签。
- 列出 Issue：按状态和标签筛选。
- 更新 Issue：使用评论、标签和关闭操作维护状态。
- 发布到 issue tracker：创建 GitHub Issue。
- 获取任务：读取对应 Issue 的正文、评论和标签。
- 外部 PR 作为需求入口：否。
- Issue 与 PR 共用编号空间，处理编号前应判断其类型。

仓库由当前目录的 Git remote 自动确定。
