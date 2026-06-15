# ADR 0002: Relay Host Agent project organization

## Status

已接受，并从 `0.2.x` baseline 开始实施。

## Context

`0.2.x` 引入 `Relay Connection` 和 macOS `CodexPort Host Agent`。它不是现有 `Direct SSH Connection` 的附加开关，而是一条同级连接方式：iOS app 连接 `CodexPort Relay`，Mac 上的 Host Agent 主动连出 Relay，并以当前 macOS 用户身份暴露该用户的 CodexPort 可连接能力。

`Codex App Control Plane Research` 与 #80 HITL 已确认：

- 现有 `codex app-server --listen stdio://` Direct SSH path 不满足 Mac Codex Desktop live UI sync。
- standalone daemon/control socket 有 same-app-server broadcast 能力，并已通过 #80 证明能驱动已打开 Codex TUI live update。
- Codex Desktop 同一 thread 不会实时显示 TUI/probe 写入；退出重进后可通过 persisted history 看到更新。因此 Codex Desktop 不再作为 live-sync gate。
- `Codex CLI Live Adapter` 应基于 `openai/codex` 公开源码、schema 和协议行为实现兼容的 live producer，作为 `Relay Connection` 的默认 TUI/iPhone live-sync 候选。

仓库需要同时承载 iOS Client 和 macOS Host Agent，并保持 shared Relay/domain/protocol contracts 可测试、可版本化、不会被 product UI 类型污染。

## Decision

当前 repo 采用两个用户面对的 product projects：

- iOS Client project：现有 iPhone-first CodexPort app。
- macOS `CodexPort Host Agent` project：新增常驻 Mac 工具 product。

SwiftPM shared/product 边界如下：

- `CodexPortCore`：现有 Direct SSH client core。
- `CodexPortShared`：`Connection Method`、`Relay Host`、`Device Identity`、`Pairing`、Relay protocol contracts、diagnostics contracts 和后续 shared test doubles。
- `CodexPortHostAgentCore`：Host Agent domain/lifecycle core，依赖 `CodexPortShared`。
- `CodexPortRelayCore`：Relay service-side auth/stream gateway core，依赖 `CodexPortShared`；它可以作为服务组件和 shared contract 一起版本化，但不是第三个用户面对 app project。
- `codexport-host-agent`：macOS Host Agent executable，依赖 `CodexPortHostAgentCore`。

Product-specific UI 和 platform concerns 必须留在各自 product project：

- iOS Client 不依赖 macOS Host Agent UI/type。
- Host Agent 不依赖 iOS SwiftUI app type。
- shared contracts 不复制粘贴到 product targets。

`Relay Connection` 默认使用 `Codex CLI Live Adapter`，不使用独立 `codex app-server --listen stdio://` 作为 live-sync 基础。`Codex CLI Live Adapter` 的目标是实现兼容官方 CLI/TUI live protocol 的 producer，不启动或控制真实 interactive TUI 进程，也不解析 TUI 屏幕。#80 证明 control-socket producer 可以驱动已打开 TUI live update，但不能驱动 Desktop live update；因此 `Shared Live Session Source` 当前定义为 TUI+iPhone live source。

`Codex CLI Live Adapter` 的 research/implementation 优先级如下：

1. 主线追踪官方 CLI/TUI 使用的公开 live protocol/schema，并实现兼容 producer。
2. standalone daemon/control socket 仅保留为 research/diagnostic surface。
3. `codex exec --json` / `codex exec resume --json` 不作为 TUI live-sync 候选；它只能用于 persisted history recovery、fallback 或测试 fixture。

`Codex CLI Live Adapter` 必须先作为独立 live-source tracer bullet 验证：不引入 P2P/WebRTC、Pairing 或 iOS UI 复杂度，只证明 HostAgent compatible producer 对同一 thread 的写入能让已经打开的 Codex TUI 实时显示该 turn。这个门槛通过前，P2P transport 通过不能被表述为 `Real-time Multi-Device Sync` 通过。

## Consequences

- 后续 issues 可以独立实现 Pairing、Relay presence、Opaque Relay Stream、Host Agent CLI live producer、multi-phone fan-out 和三端 verification。
- CI/build matrix 应分别验证 iOS Client、macOS Host Agent 和 shared modules。
- Relay service-side code 进入 repo 时应保持为 service component boundary，默认只处理 auth/routing/telemetry，不把 Codex payload source of truth 或产品 UI 引入 Relay target。
- Direct SSH baseline 不被 `0.2.x` 改动替换；ADR 0001 仍约束现有 `SSHDriver` path。
- `Relay Connection` 的产品表述必须以 Codex TUI + iPhoneA + iPhoneB 端到端验证为准，不能仅凭 persisted state 宣称满足 `Real-time Multi-Device Sync`。
- persisted-history-only 体验不作为 `Relay Connection` 的可发布降级方向。如果无法找到稳定可授权的 `Shared Live Session Source`，相关远程同步能力应保持 blocked/experimental，而不是发布一个需要用户退出重进 Desktop/TUI 会话才能同步的体验。
- 当前 Relay/HostAgent live-sync 实现不是兼容性约束。为满足 `Shared Live Session Source` 和 `TUI Live Sync`，可以丢弃或重构现有 `codex-exec-json` backend、local relay bridge、HostAgent live adapter 和相关 P2P/Relay glue code。不要为了保留当前实现而降低 live-sync 验收标准。
- `Codex CLI Live Adapter + TUI Live Sync` 应作为 #63 `P2P-first Remote Connection` 的前置 gate。#63 的 WebRTC/DataChannel work 可以在 TUI live-source tracer bullet 通过后恢复为 canonical implementation entry。
