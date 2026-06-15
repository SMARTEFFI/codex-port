# Issue #83 P2P gate for PRD #63

Status: **unblocked by #80 TUI live sync pass**.

## Gate statement

#63 `P2P-first Remote Connection` cannot be treated as the canonical implementation path until `Codex CLI Live Adapter + TUI Live Sync` proves a `Shared Live Session Source`.

P2P/WebRTC transport can move bytes between iOS and HostAgent, but it does not by itself satisfy `Real-time Multi-Device Sync`. The release-significant gate is:

- already-open Codex TUI session receives HostAgent-submitted user message live.
- already-open Codex TUI session receives final assistant message live.
- iOS/HostAgent receives write status and live assistant progress.
- this happens without exiting/reopening TUI session.

Codex Desktop is explicitly outside this gate. In #80, Desktop was confirmed on
the same session `019ea4d7-6c12-7132-8fad-4cd2028309ba`; it did not live-update
from either the control-socket producer or a direct official TUI message, and
only showed the new turn after exit/reopen through persisted history.

## Allowed before gate passes

- Continue public CLI/TUI protocol/schema research.
- Implement compatible live producer contract behind fakes.
- Implement diagnostics that reject persisted-history-only sources.
- Keep Direct SSH baseline working.
- Keep existing P2P code as experimental/prototype code if needed for later reuse.

## Not allowed before gate passes

- Mark #63 as `Real-time Multi-Device Sync` complete without TUI+iPhone verification.
- Release persisted-history-only behavior as `TUI Live Sync`.
- Treat `codex exec --json` / `codex exec resume --json` as live source.
- Treat Desktop reload-after-reopen as live-sync evidence.

## Current code gate

`HostAgentLiveSyncDiagnosticReport` now classifies live sources:

- `.codexCLILiveAdapter(evidence:)` passes when evidence records the TUI live tracer result.
- `.appServerControlSocketTUILive(evidence:)` passes when evidence records the #80 control-socket TUI live result.
- `.codexExecJSON` fails as persisted-history-only.
- `.standaloneDaemonControlSocket` fails as diagnostic-only.
- `.unknown(reason:)` fails and leaves TUI live sync not run.

Production HostAgent backend defaults to `codex-cli-live`. Set it explicitly in
manual runs only when you want the run log to show the selected backend:

```sh
CODEXPORT_HOST_AGENT_BACKEND=codex-cli-live
CODEXPORT_CODEX_CONTROL_SOCKET_PATH="$HOME/.codex/app-server-control/app-server-control.sock"
```

`codex-cli-live` selects `HostAgentCodexCLILiveAdapter + CodexAppServerControlSocketLiveProducer` and maps app-server control-socket notifications into `RelayLiveSessionEvent` / `Client-Host Session Protocol` events.

## Reopen condition for #63 implementation

After #80 first-stage TUI pass, #63 can resume with this order:

1. Use the default `codex-cli-live` HostAgent producer for local/P2P runs, optionally setting `CODEXPORT_HOST_AGENT_BACKEND=codex-cli-live` explicitly in the shell for auditability.
2. Reconnect P2P/WebRTC transport to the verified producer.
3. Run Codex TUI + iPhone simulator + real iPhone verification.

#63 is unblocked for implementation. It is not release-ready until TUI+iPhone verification passes over the real P2P path.
