# CodexPort Host Agent macOS App

`codexport-host-agent-menu` is a SwiftPM-built menu-bar executable wrapped in a
stable macOS menu-bar app at `.scratch/apps/CodexPort Host Agent.app`. The wrapper
uses the fixed bundle identifier `com.smarteffi.codexport.hostagent` and is signed
with the first available local Apple codesigning identity unless
`CODEXPORT_CODESIGN_IDENTITY` overrides it.

The WebRTC helper is also wrapped as `.scratch/webrtc-sidecar/CodexPort WebRTC
Sidecar.app` with bundle identifier `com.smarteffi.codexport.webrtc-sidecar`.
Both bundles include `NSLocalNetworkUsageDescription` so macOS Local Network
privacy prompts bind to stable app identities instead of rebuilt ad-hoc
executables.

## Build

```bash
scripts/build-host-agent-app.sh
```

The generated debug wrapper is:

```text
.scratch/apps/CodexPort Host Agent.app
```

Verify local-network signing before manual device validation:

```bash
scripts/verify-hostagent-local-network-signing.sh
```

## Menu P2P Start Path

Use this path for manual pairing from the menu bar:

```bash
scripts/start-host-agent-menu-p2p.sh
```

The helper builds the signed HostAgent menu app, builds the signed WebRTC sidecar
app, stops older CLI/menu HostAgent processes, and starts the app executable
through a run-scoped LaunchAgent. The LaunchAgent uses `/usr/bin/env -i` and
passes only the minimum HostAgent environment (`CODEXPORT_*`, `PATH`, `HOME`,
`USER`) so it does not inherit local credential variables from the user launch
environment.

Expected output:

```text
CODEXPORT_HOSTAGENT_MENU_PID=...
CODEXPORT_HOSTAGENT_MENU_STDOUT=...
CODEXPORT_HOSTAGENT_MENU_STDERR=...
CODEXPORT_HOSTAGENT_MENU_LAUNCHD_PLIST=...
```

Use the menu bar icon and choose `New Pairing`.

## Relay Environment

The app reads Relay configuration from the user launch environment. For the
current VPS smoke:

```bash
launchctl setenv CODEXPORT_RELAY_BASE_URL https://codexport.smarteffi.net
launchctl setenv CODEXPORT_RELAY_HOST_ID 11111111-2222-3333-4444-555555555555
launchctl setenv CODEXPORT_RELAY_HOST_NAME "CodexPort Dev Mac"
launchctl setenv CODEXPORT_RELAY_HOST_USER "$USER"
launchctl setenv CODEXPORT_CODEX_CONTROL_SOCKET_PATH "$HOME/.codex/app-server-control/app-server-control.sock"
open ".scratch/apps/CodexPort Host Agent.app"
```

`LSUIElement=true` is set in `Info.plist`, so the app does not appear in the
Dock. Use the menu bar icon to open the window and choose `New Pairing`.

For the #63/#74 TUI live-sync gate, `codex-cli-live` is the default HostAgent
backend. The older `codex-exec-json` backend is useful for local JSONL smoke
tests only when explicitly selected; it does not prove live updates in an
already-open Codex TUI session.

## HITL CLI Start Path

Use this CLI path for lower-level real TUI/iPhone HITL when the menu app is not
needed:

```bash
eval "$(zsh scripts/issue74-start-hostagent-p2p.sh "ISSUE74-PHYSICAL-IDLE-TUI-<timestamp>")"
```

The helper builds `codexport-host-agent`, builds the WebRTC sidecar, writes a
fresh LaunchAgent plist under `.scratch/launchagents/`, restarts
`codexport-host-agent --p2p-listen`, checks the production Relay P2P host drain,
and exports:

```bash
CODEXPORT_ISSUE74_RUN_ID
CODEXPORT_HOSTAGENT_STDOUT
CODEXPORT_HOSTAGENT_STDERR
CODEXPORT_HOSTAGENT_LAUNCHD_PLIST
```

Use those exported values when running the #74 metadata verifier after
TestFlight/manual iPhoneA + iPhoneB attachment.

For diagnosis, the equivalent manual start path is:

```bash
swift build --product codexport-host-agent
WEBRTC_SIDECAR_PATH="$(scripts/build-webrtc-sidecar.sh | tail -n 1)"

CODEXPORT_RELAY_BASE_URL=https://codexport.smarteffi.net \
CODEXPORT_RELAY_HOST_ID=11111111-2222-3333-4444-555555555555 \
CODEXPORT_RELAY_HOST_NAME="CodexPort Dev Mac" \
CODEXPORT_RELAY_HOST_USER="$USER" \
CODEXPORT_CODEX_CONTROL_SOCKET_PATH="$HOME/.codex/app-server-control/app-server-control.sock" \
CODEXPORT_WEBRTC_SIDECAR_PATH="$WEBRTC_SIDECAR_PATH" \
CODEXPORT_WEBRTC_SIDECAR_ARGUMENTS_JSON='["--stdio-jsonl"]' \
.build/debug/codexport-host-agent --p2p-listen
```

The command should print `P2P signaling listener polling ...` and stay resident
until SIGINT/SIGTERM. A TLS/poll failure against a placeholder Relay URL proves
the listener loop is alive, but does not prove the production Relay/TURN path.

`scripts/build-webrtc-sidecar.sh` builds the Mac Catalyst sidecar with the real
`WebRTC.framework`, copies it to `.scratch/webrtc-sidecar/CodexPort WebRTC
Sidecar.app`, rewrites the framework rpath to `@executable_path/../Frameworks`,
and signs the helper bundle. A JSONL smoke with a deliberately invalid SDP should
fail with a WebRTC SDP error, not `runtimeUnavailable` or a dyld framework error.
