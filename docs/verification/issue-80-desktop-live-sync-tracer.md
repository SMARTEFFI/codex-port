# Issue #80 TUI live sync tracer bullet

Status: **passed for TUI, failed for Desktop live update**.

Purpose: prove `HostAgentCodexCLILiveAdapter` can drive an already-open Codex TUI session through the public CLI/TUI live protocol. This is the live-source gate before reconnecting the work to #63 P2P/WebRTC.

## Scope

In scope:

- HostAgent compatible live producer opens/resumes an existing thread.
- iOS/test client submits a prompt through HostAgent.
- Codex TUI is already open on the same thread before the prompt is sent.
- Codex TUI updates live without exiting/reopening the session.
- HostAgent/iOS receives live progress and terminal write status.
- Codex Desktop may show the new turn after exit/reopen via persisted history, but Desktop live update is not required by this gate.

Out of scope:

- Launching or controlling a real interactive TUI process.
- Parsing TUI screen output.
- Calling closed-source Desktop private APIs.
- Proving P2P/WebRTC transport behavior.

## Pass criteria

First-stage pass requires all of:

1. Codex TUI already displays the target thread.
2. HostAgent compatible live producer attaches to that same thread.
3. A prompt sent through HostAgent appears in the already-open TUI session without reopening.
4. The final assistant message appears in the already-open TUI session without reopening.
5. HostAgent/iOS event stream includes write status `queued -> running -> handled` or an explicit failed reason.
6. HostAgent/iOS event stream includes assistant progress before final completion when the public protocol exposes it.

Second-stage pass adds:

1. command output live events.
2. file change live events.
3. approval request and response events.

## Current automated coverage

Implemented by tests:

- `HostAgentCodexCLILiveAdapterTests.codexCLILiveAdapterMapsPublicLiveProducerEventsAndSerializedWrites`
- `HostAgentCodexCLILiveAdapterTests.codexCLILiveAdapterReportsProducerRejectedPromptWithoutLeakingPromptPlaintext`
- `HostAgentCodexCLILiveAdapterTests.liveSessionBridgeStopsCodexCLILiveAdapterProducer`
- `HostAgentDiagnosticsTests.hostAgentLiveSyncDiagnosticsRejectsPersistedHistoryOnlySources`
- `HostAgentDiagnosticsTests.hostAgentLiveSyncDiagnosticsAcceptsOnlyVerifiedCodexCLILiveAdapter`

These tests validate CodexPort's adapter contract and persisted-history-only guard. They do **not** prove TUI live UI sync; the #80 HITL run below does.

## HITL runbook

1. Build and start the latest HostAgent.
2. Open official `codex` TUI on a known thread.
3. Start a test client that connects to HostAgent's `CodexCLILiveProducing` implementation for that thread.
4. Send prompt `LIVE-TRACE-<timestamp>` through HostAgent.
5. Observe TUI without exiting/reopening the thread.
6. Capture evidence:
   - TUI shows `LIVE-TRACE-<timestamp>` user message live.
   - TUI shows final assistant response live.
   - HostAgent/iOS logs show only metadata/byte counts, not prompt or assistant plaintext.
   - Client event log shows write status and assistant live events.
7. Record pass/fail on issue #80 with exact date, Codex CLI version, and thread id.

## 2026-06-14 HITL result

Thread id: `019ea4d7-6c12-7132-8fad-4cd2028309ba`.

Marker: `ISSUE80-LIVE-TRACE-20260614150351`.

Probe sequence:

1. WebSocket-over-UDS connect to `~/.codex/app-server-control/app-server-control.sock`.
2. `initialize`.
3. `initialized`.
4. `thread/resume`.
5. `turn/start`.

Observed probe events:

- `turn/started`.
- repeated `item/agentMessage/delta`.
- `item/completed`.
- `thread/status/changed`.
- `turn/completed`.

Human observation:

- Already-open Codex TUI showed `ISSUE80-LIVE-TRACE-20260614150351收到` live.
- Codex Desktop was confirmed open on session `019ea4d7-6c12-7132-8fad-4cd2028309ba`, the same session used by the TUI/probe.
- Already-open Codex Desktop did not update live.
- After quitting and reopening Desktop on the same session, Desktop showed `ISSUE80-LIVE-TRACE-20260614150351 收到` from persisted history.
- A separate message sent directly from the official Codex TUI also did not update the already-open Desktop session live.

Conclusion:

- #80 passes for TUI live sync.
- The original assumption that official Codex TUI and Codex Desktop provide bidirectional open-session real-time sync was false for this thread.
- Desktop is not part of the real-time gate; it behaves as persisted-history reload for this scenario.
- #63/#74 should therefore verify live sync across the already-open Codex TUI plus connected iPhone clients, not Codex Desktop.
- CodexPort only needs to make the TUI live source and iPhone clients synchronize in real time; Desktop may remain a persisted-history observer.

## Failure interpretation

- If TUI only updates after exit/reopen, this is persisted-history-only and fails #80.
- If HostAgent/iOS sees events but TUI does not, the producer is not connected to the shared live source.
- If TUI updates but HostAgent/iOS lacks progress/write status, #80 first-stage may pass, but #82 remains incomplete.
