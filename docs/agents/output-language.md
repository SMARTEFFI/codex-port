# Output Language

本仓库安装的 mattpocock/skills 产出的所有 artifacts 默认使用中文。

这适用于面向用户的交付物，例如 PRDs、issue bodies、triage comments、agent briefs、handoff notes、architecture reports、prototype notes、ADRs、glossary entries、test plans、diagnosis summaries 和 review summaries。

如果翻译会破坏 label lookup、workflow state transitions、命令、templates、代码引用或共享词汇，则必须原样保留关键英文术语。不要翻译：

- issue tracker commands 和 flags，例如 `gh issue create`、`--add-label` 和 `--body`
- triage category labels 和 state labels，例如 `bug`、`enhancement`、`needs-triage`、`needs-info`、`ready-for-agent`、`ready-for-human` 和 `wontfix`
- workflow 和 skill names，例如 `AFK`、`HITL`、`PRD`、`ADR`、`CONTEXT.md`、`docs/adr/`、`triage`、`to-issues`、`to-prd`、`diagnose`、`tdd`、`improve-codebase-architecture` 和 `zoom-out`
- template keys、Markdown headings、文件名、paths、code identifiers、API names、type names、function names、environment variables，以及需要照抄的 CLI output
- skill 定义的 architecture vocabulary，例如 `module`、`interface`、`implementation`、`depth`、`deep`、`shallow`、`seam`、`adapter`、`leverage` 和 `locality`

当 template 包含 English headings 或 machine-readable markers 时，如果其他 skills 可能解析或引用它们，应保留这些 headings 或 markers。heading 下的说明内容使用中文。

如果用户明确要求某个具体交付物使用其他语言，应遵循该请求，同时保留上面列出的英文术语。
