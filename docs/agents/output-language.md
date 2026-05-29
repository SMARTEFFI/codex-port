# Output Language

All artifacts produced by the mattpocock/skills installed in this repo should use Chinese as the default language.

This applies to user-facing deliverables such as PRDs, issue bodies, triage comments, agent briefs, handoff notes, architecture reports, prototype notes, ADRs, glossary entries, test plans, diagnosis summaries, and review summaries.

Preserve critical English terms exactly when changing them could break label lookup, workflow state transitions, commands, templates, code references, or shared vocabulary. Do not translate:

- issue tracker commands and flags, such as `gh issue create`, `--add-label`, and `--body`
- triage category labels and state labels, such as `bug`, `enhancement`, `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, and `wontfix`
- workflow and skill names, such as `AFK`, `HITL`, `PRD`, `ADR`, `CONTEXT.md`, `docs/adr/`, `triage`, `to-issues`, `to-prd`, `diagnose`, `tdd`, `improve-codebase-architecture`, and `zoom-out`
- template keys, Markdown headings, file names, paths, code identifiers, API names, type names, function names, environment variables, and CLI output that should be copied verbatim
- architecture vocabulary defined by a skill, such as `module`, `interface`, `implementation`, `depth`, `deep`, `shallow`, `seam`, `adapter`, `leverage`, and `locality`

When a template includes English headings or machine-readable markers, keep those headings or markers if other skills may parse or refer to them. Write the explanatory content under those headings in Chinese.

If a user explicitly asks for another language for a specific deliverable, follow that request while preserving the same English terms above.
