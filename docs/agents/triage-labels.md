# Triage Labels

skills 会使用五种标准 triage roles。此文件把这些 roles 映射到本仓库 issue tracker 实际使用的 label 字符串。

artifact 正文默认使用中文，但表格中的 canonical role names 和 tracker label strings 必须保持不变，除非项目明确重命名 labels。参见 `docs/agents/output-language.md`。

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | 维护者需要评估此 issue                   |
| `needs-info`               | `needs-info`         | 等待报告者提供更多信息                   |
| `ready-for-agent`          | `ready-for-agent`    | 规格已完整，可交给 AFK agent             |
| `ready-for-human`          | `ready-for-human`    | 需要人工实现或判断                       |
| `wontfix`                  | `wontfix`            | 不会处理                                 |

当 skill 提到某个 role（例如 "apply the AFK-ready triage label"）时，使用此表中对应的 label string。

如果实际 tracker 使用了不同词汇，只修改右侧列以匹配真实 label。
