# CodexPort Host Agent macOS App

`codexport-host-agent-menu` is a SwiftPM-built menu-bar executable. The
temporary `.scratch/apps/CodexPort Host Agent.app` wrapper is useful for bundle
layout work, but it is not the authoritative HITL start path until the project
has a properly signed macOS app target.

For #63/#74 HITL, use the shared helper or the menu helper so the run always
uses the latest compiled HostAgent bits.

## Build

```bash
scripts/build-host-agent-app.sh
```

The generated debug wrapper is:

```text
.scratch/apps/CodexPort Host Agent.app
```

On this machine, direct execution through that temporary `.app` wrapper can be
rejected by AppleSystemPolicy/AMFI because the copied SwiftPM debug executable is
ad-hoc signed. Treat that as a packaging/signing task, not as evidence that the
HostAgent product cannot run.

## Menu P2P Start Path

Use this path for manual pairing from the menu bar while the temporary `.app`
wrapper remains a packaging task:

```bash
scripts/start-host-agent-menu-p2p.sh
```

The helper builds `codexport-host-agent-menu`, builds the WebRTC sidecar, stops
older CLI/menu HostAgent processes, and starts the menu executable through a
run-scoped LaunchAgent. The LaunchAgent uses `/usr/bin/env -i` and passes only
the minimum HostAgent environment (`CODEXPORT_*`, `PATH`, `HOME`, `USER`) so it
does not inherit local credential variables from the user launch environment.

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

Use this path before real TUI/iPhone HITL until a signed macOS app target exists:

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
scripts/build-webrtc-sidecar.sh

CODEXPORT_RELAY_BASE_URL=https://codexport.smarteffi.net \
CODEXPORT_RELAY_HOST_ID=11111111-2222-3333-4444-555555555555 \
CODEXPORT_RELAY_HOST_NAME="CodexPort Dev Mac" \
CODEXPORT_RELAY_HOST_USER="$USER" \
CODEXPORT_CODEX_CONTROL_SOCKET_PATH="$HOME/.codex/app-server-control/app-server-control.sock" \
CODEXPORT_WEBRTC_SIDECAR_PATH="$PWD/.scratch/webrtc-sidecar/codexport-webrtc-sidecar" \
CODEXPORT_WEBRTC_SIDECAR_ARGUMENTS_JSON='["--stdio-jsonl"]' \
.build/debug/codexport-host-agent --p2p-listen
```

The command should print `P2P signaling listener polling ...` and stay resident
until SIGINT/SIGTERM. A TLS/poll failure against a placeholder Relay URL proves
the listener loop is alive, but does not prove the production Relay/TURN path.

`scripts/build-webrtc-sidecar.sh` builds the Mac Catalyst sidecar with the real
`WebRTC.framework`, copies it to `.scratch/webrtc-sidecar`, rewrites the
framework rpath to `@executable_path/PackageFrameworks`, and ad-hoc signs the
helper for local HITL. A JSONL smoke with a deliberately invalid SDP should fail
with a WebRTC SDP error, not `runtimeUnavailable` or a dyld framework error.
