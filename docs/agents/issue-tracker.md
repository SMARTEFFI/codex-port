# Issue tracker: GitHub

本仓库的 issues 和 PRDs 以 GitHub issues 形式维护。所有操作都使用 `gh` CLI。

发布 issue tracker artifact 时，正文默认使用中文，并按 `docs/agents/output-language.md` 保留关键英文术语。

## Conventions

- **Create an issue**：`gh issue create --title "..." --body "..."`。多行 body 使用 heredoc。
- **Read an issue**：`gh issue view <number> --comments`，用 `jq` 过滤 comments，并同时获取 labels。
- **List issues**：`gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`，按需要加上合适的 `--label` 和 `--state` 过滤。
- **Comment on an issue**：`gh issue comment <number> --body "..."`
- **Apply / remove labels**：`gh issue edit <number> --add-label "..."` / `--remove-label "..."`
- **Close**：`gh issue close <number> --comment "..."`

仓库从 `git remote -v` 推断；在 clone 内运行时，`gh` 会自动完成这一点。

## When a skill says "publish to the issue tracker"

创建一个 GitHub issue。

## When a skill says "fetch the relevant ticket"

运行 `gh issue view <number> --comments`。
