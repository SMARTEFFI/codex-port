# Domain Docs

engineering skills 在探索代码库时，应按此说明读取本仓库的领域文档。

当这些文档影响生成的 artifacts 时，正文默认使用中文；必要时原样保留 domain terms、文件名、code identifiers、ADR IDs、labels 和 workflow terms。参见 `docs/agents/output-language.md`。

## Before exploring, read these

- 仓库根目录下的 **`CONTEXT.md`**，或者
- 如果根目录存在 **`CONTEXT-MAP.md`**，则读取它指向的每个 context 对应的 `CONTEXT.md`。只读取与当前主题相关的内容。
- **`docs/adr/`**：读取与即将处理区域相关的 ADRs。在 multi-context repos 中，也检查 `src/<context>/docs/adr/` 中的 context-scoped decisions。

如果这些文件不存在，**静默继续**。不要报告缺失，也不要预先建议创建。producer skill（`/grill-with-docs`）会在术语或决策真正被明确时再懒创建。

## File structure

Single-context repo（大多数仓库）：

```
/
├── CONTEXT.md
├── docs/adr/
│   ├── 0001-event-sourced-orders.md
│   └── 0002-postgres-for-write-model.md
└── src/
```

Multi-context repo（根目录存在 `CONTEXT-MAP.md`）：

```
/
├── CONTEXT-MAP.md
├── docs/adr/                          ← system-wide decisions
└── src/
    ├── ordering/
    │   ├── CONTEXT.md
    │   └── docs/adr/                  ← context-specific decisions
    └── billing/
        ├── CONTEXT.md
        └── docs/adr/
```

## Use the glossary's vocabulary

当输出中命名领域概念时（例如 issue title、refactor proposal、hypothesis、test name），使用 `CONTEXT.md` 中定义的术语。不要漂移到 glossary 明确避免的同义词。

如果你需要的概念尚未出现在 glossary 中，这是一个信号：要么你正在发明项目并不使用的语言（需要重新考虑），要么确实存在术语缺口（记录给 `/grill-with-docs`）。

## Flag ADR conflicts

如果输出与已有 ADR 冲突，应明确指出，而不是静默覆盖：

> _Contradicts ADR-0007 (event-sourced orders) — but worth reopening because…_
