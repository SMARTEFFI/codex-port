# Codex CLI Live Adapter public protocol research

Status: **active for PRD #77 / issues #78-#83**.

## Decision context

#80 HITL 纠正了早期假设：官方 `codex` CLI/TUI 与闭源 Codex Desktop App 并不能稳定做到 open-session live sync。真实观察是：HostAgent-compatible public protocol probe 和 Codex TUI 之间可以实时同步；Codex Desktop 打开同一 session `019ea4d7-6c12-7132-8fad-4cd2028309ba` 时不会实时更新，退出重进后可通过 persisted history 看到新 turn。从官方 Codex TUI 直接发送消息也不会让已打开 Desktop 实时更新。

Codex Desktop App 闭源，因此 CodexPort 不把 Desktop private interface、renderer IPC、process injection、screen parsing 或 binary reverse engineering 当作实现路线。当前路线只分析官方公开的 `codex` CLI/TUI source、schema 和 protocol 行为，目标是在 HostAgent 内实现一个兼容 live producer，让 iOS 写入进入同一个 TUI live synchronization 机制。Desktop 只作为 persisted history viewer，不作为实时同步 gate。

## Protocol surface

公开 CLI/TUI live protocol 的研究入口是 `openai/codex` app-server / app-server-protocol schema 与生成 types。当前本机研究产物位于 `.scratch/research/app-schema/`，其中与 live session 相关的 schema 包括：

- `ClientRequest.json`
- `ServerNotification.json`
- `ServerRequest.json`
- `JSONRPCMessage.json`
- `CommandExecutionRequestApprovalParams.json`
- `FileChangeRequestApprovalParams.json`
- `ExecCommandApprovalParams.json`
- `ApplyPatchApprovalParams.json`
- `ToolRequestUserInputParams.json`

这些 schema 说明公开协议至少覆盖：

- thread open/resume/start 与 turn start/interrupt。
- assistant message delta/completed。
- command output、file changes、approval requests。
- request/response/notification 的 JSON-RPC framing。

具体最小字段 evidence：

- `v2/ThreadResumeParams.ts`：`threadId` 是恢复 running thread 的首选身份；schema 注释说明如果 `thread_id` 指向 running thread，app-server 会 rejoin 该 thread，并把非空 path 作为 active rollout path consistency check。
- `v2/TurnStartParams.ts`：`threadId`、`clientUserMessageId`、`input: Array<UserInput>` 构成 prompt write 的最小入口，并可携带 cwd、runtime workspace roots、approval policy、sandbox、model、collaboration mode 等 turn-scoped override。
- `v2/TurnStartedNotification.ts` / `v2/TurnCompletedNotification.ts`：notification 携带 `threadId` 与 `turn`，可作为 turn lifecycle bridge。
- `v2/ThreadStatusChangedNotification.ts`：notification 携带 `threadId` 与 status，可作为 running/completed/failed projection 的补充。
- `v2/AgentMessageDeltaNotification.ts`：`threadId`、`turnId`、`itemId`、`delta` 是 assistant progress 的最小 live shape。
- `v2/ItemCompletedNotification.ts`：`item`、`threadId`、`turnId`、`completedAtMs` 可作为 assistant final/tool/file final item bridge。
- `v2/CommandExecutionOutputDeltaNotification.ts`：`threadId`、`turnId`、`itemId`、`delta` 是 command output progress 的最小 live shape。
- `v2/FileChangeOutputDeltaNotification.ts`：存在 legacy apply-patch textual output shape，但 schema 注释标记 deprecated/server no longer emits；真实 file change bridge 应优先依赖 item completion / approval schema，而不是这个 deprecated notification。
- `CommandExecutionRequestApprovalParams`、`FileChangeRequestApprovalParams`、`ExecCommandApprovalParams`、`ApplyPatchApprovalParams`、`PermissionsRequestApprovalParams`、`ToolRequestUserInputParams` 说明 approval/request surface 在公开 schema 内。

CodexPort 的 `Codex CLI Live Adapter` 只承接这个公开协议层的 live producer contract。它不是：

- 启动或控制真实 interactive TUI process/PTY。
- 解析 TUI screen。
- 调用闭源 Desktop private API。
- 使用 `codex exec --json` 伪装 live session。

## Candidate assessment

### Accepted candidate: compatible CLI/TUI live producer

HostAgent 应实现一个兼容 public CLI/TUI live protocol 的 producer，并把 producer events 桥接到 `Client-Host Session Protocol` / `RelayLiveSessionEvent`：

- `sessionOpened` -> `sessionStarted`
- assistant delta/final -> `assistantTextDelta`
- command output -> `commandOutputDelta`
- file change -> `fileChange`
- approval request -> `approvalRequested`
- turn terminal state -> `turnCompleted` / `turnFailed`
- stream close -> `streamClosed`

当前代码中的最小 contract 是 `CodexCLILiveProducing` 与 `HostAgentCodexCLILiveAdapter`。fake producer 测试已覆盖 open session、serialized prompt write、live assistant/tool/approval event fan-out、rejected write status 和 stop lifecycle。

2026-06-15 implementation update:

- `CodexAppServerControlSocketLiveProducer` implements the #80-proven control-socket path as a production `CodexCLILiveProducing` implementation.
- `CodexAppServerControlWebSocketTransport` connects to `~/.codex/app-server-control/app-server-control.sock` using WebSocket-over-UDS and sends JSON-RPC requests over the public app-server protocol.
- `codex-cli-live` is the production default backend in `HostAgentCommandLineConfiguration` and selects `HostAgentCodexCLILiveAdapter + CodexAppServerControlSocketLiveProducer`; `CODEXPORT_HOST_AGENT_BACKEND` remains an explicit override for fixtures/fallbacks.
- `CODEXPORT_CODEX_CONTROL_SOCKET_PATH` can override the socket path for local verification.
- Real control-socket `turn/completed` notifications have been observed with
  the terminal id nested at `turn.id`, not only as top-level `turnId`.
  `CodexAppServerControlSocketLiveProducer` accepts both shapes when mapping
  completion/failure and live item events.
- Focused tests prove `initialize -> thread/resume -> turn/start`, accepted
  prompt writes, assistant delta, `item/completed`, nested-`turn.id`
  `turn/completed`, rejected write status, and HostAgent local relay /
  `Client-Host Session Protocol` fan-out.
- Simulator P2P rehearsal `SIM-P2P-LIVE-075304` passed after this mapping fix:
  two simulator clients attached through production Relay signaling + WebRTC
  sidecar + control-socket producer and both received `handled`,
  `assistantTextDelta`, and `turnCompleted` metadata for the same turn. This is
  still rehearsal evidence; #74 requires physical iPhoneA + iPhoneB and human
  observation of the already-open TUI.
- `SIM-P2P-LIVE-082655` repeated the same idle-thread gate through the shared
  HostAgent P2P start helper. The run-id-scoped verifier proved the iPhoneA
  simulator identity was the prompt sender, the iPhoneB simulator identity was
  observer-only, and both received the same handled write id and completed live
  turn id.

### Rejected for live sync: `codex exec --json`

`codex exec --json` / `codex exec resume --json` 是 one-shot persisted history path。它可以用于 fallback、history recovery、fixtures 或 diagnostics，但不能更新已经打开的 TUI live session，因此不能作为 `TUI Live Sync` candidate。

`HostAgentLiveSyncDiagnosticReport` 已把 `.codexExecJSON` 标为 failed live source，防止后续把 persisted-history-only 体验误报为 live sync ready。

### Accepted for TUI live source: standalone daemon/control socket

standalone app-server control socket 可用于 public schema research、same-app-server broadcast 和 TUI live sync。#80 证明 WebSocket-over-UDS probe 通过 `thread/resume -> turn/start` 可以让已打开 TUI 实时显示 user message 和 final assistant message。

同一实验也证明 Desktop open-session 不会实时更新，退出重进后才通过 persisted history 可见。因此 Desktop live update 不再作为 gate。

## Tracer bullet gate

在继续 #63 P2P/WebRTC 之前，必须先通过 `Codex CLI Live Adapter + TUI Live Sync` tracer bullet：

1. Codex TUI 已经打开目标 thread。
2. HostAgent compatible live producer 连接同一 thread。
3. iOS 或 test client 通过 HostAgent submit prompt。
4. 已打开 TUI session 不退出、不重进，实时显示 user message。
5. 已打开 TUI session 实时显示 final assistant message。
6. HostAgent/iOS 侧同时显示 write status 与 assistant progress。

第一阶段只要求 TUI user message + final assistant message live update。tool/file/approval live events 是第二阶段验收。Desktop reload-after-reopen evidence 不能作为实时同步证据。

## Current implementation status

已实现：

- `CodexCLILiveProducing` public-protocol-facing contract。
- `CodexCLILiveEventBridge` 到 `RelayLiveSessionEvent` 的映射。
- `HostAgentCodexCLILiveAdapter` lifecycle、serialized prompt write handling 和 event fan-out。
- `HostAgentLiveSessionBridge` 对 `HostAgentCodexCLILiveAdapter.stop()` 的 lifecycle forwarding。
- `HostAgentLiveSyncDiagnosticReport` persisted-history-only guard。
- `CodexAppServerControlSocketLiveProducer` production producer for the #80 control-socket TUI live path。
- `codex-cli-live` HostAgent production-default backend selection。
- HostAgent local relay / `Client-Host Session Protocol` fan-out through the `codex-cli-live` producer。

未实现：

- Full #74 HITL: real Mac HostAgent + already-open Codex TUI + iPhoneA + iPhoneB over the real P2P path。
- Approval/file/tool live event completeness beyond the first user/final assistant tracer path。
- #63 P2P/WebRTC real-device reconnect verification。

## Superseded note

`docs/research/codex-app-control-plane.md` 中“Host Agent 管理真实 `codex` CLI process/PTY”的历史建议已被 PRD #77 决策替代。当前目标是 compatible live producer，不控制真实 TUI，不解析 TUI screen。
