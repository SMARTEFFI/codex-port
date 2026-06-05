## Agent skills

### Output language

mattpocock/skills 产出的所有 artifact 默认使用中文。遇到 label、workflow state、命令、template key、文件名、代码标识符或既有 skill 术语时，关键英文词必须保持不变。参见 `docs/agents/output-language.md`。

### Issue tracker

Issues 和 PRDs 使用 GitHub Issues 跟踪，所有操作通过 `gh` CLI 完成。参见 `docs/agents/issue-tracker.md`。

### Triage labels

使用 mattpocock/skills 默认的 triage labels。参见 `docs/agents/triage-labels.md`。

### Domain docs

这是 single-context repo：如果根目录存在 `CONTEXT.md`，以及存在 `docs/adr/`，应读取它们。参见 `docs/agents/domain.md`。
