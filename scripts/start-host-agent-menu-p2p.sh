#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

HOST_ID="${CODEXPORT_RELAY_HOST_ID:-11111111-2222-3333-4444-555555555555}"
HOST_NAME="${CODEXPORT_RELAY_HOST_NAME:-CodexPort Dev Mac}"
HOST_USER="${CODEXPORT_RELAY_HOST_USER:-${USER:-macos}}"
RELAY_BASE_URL="${CODEXPORT_RELAY_BASE_URL:-https://codexport.smarteffi.net}"
CODEX_CONTROL_SOCKET_PATH="${CODEXPORT_CODEX_CONTROL_SOCKET_PATH:-$HOME/.codex/app-server-control/app-server-control.sock}"
WEBRTC_SIDECAR_DEFAULT_PATH="$ROOT_DIR/.scratch/webrtc-sidecar/CodexPort WebRTC Sidecar.app/Contents/MacOS/codexport-webrtc-sidecar"
WEBRTC_SIDECAR_PATH="${CODEXPORT_WEBRTC_SIDECAR_PATH:-$WEBRTC_SIDECAR_DEFAULT_PATH}"
WEBRTC_SIDECAR_ARGUMENTS_JSON="${CODEXPORT_WEBRTC_SIDECAR_ARGUMENTS_JSON:-[\"--stdio-jsonl\"]}"
MENU_APP_PATH="${CODEXPORT_HOST_AGENT_MENU_APP_PATH:-$ROOT_DIR/.scratch/apps/CodexPort Host Agent.app}"
MENU_EXECUTABLE="${CODEXPORT_HOST_AGENT_MENU_EXECUTABLE:-$MENU_APP_PATH/Contents/MacOS/codexport-host-agent-menu}"
LOG_DIR="$ROOT_DIR/.scratch/logs"
RUNTIME_DIR="$ROOT_DIR/.scratch/runtime"
STDOUT_LOG="$LOG_DIR/hostagent-menu-p2p.out"
STDERR_LOG="$LOG_DIR/hostagent-menu-p2p.err"
PID_FILE="$ROOT_DIR/.scratch/hostagent-menu-p2p.pid"
LAUNCHD_LABEL="${CODEXPORT_HOSTAGENT_MENU_LAUNCHD_LABEL:-com.smarteffi.codexport.hostagent.menu.p2p}"
LAUNCHD_PLIST="${CODEXPORT_HOSTAGENT_MENU_LAUNCHD_PLIST:-$ROOT_DIR/.scratch/launchagents/${LAUNCHD_LABEL}.plist}"

mkdir -p "$LOG_DIR" "$RUNTIME_DIR"
mkdir -p "$(dirname "$LAUNCHD_PLIST")"

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

echo "Building HostAgent menu app..." >&2
scripts/build-host-agent-app.sh >&2

if [[ "${CODEXPORT_SKIP_WEBRTC_SIDECAR_BUILD:-0}" != "1" ]]; then
  echo "Building WebRTC sidecar..." >&2
  WEBRTC_SIDECAR_PATH="$(scripts/build-webrtc-sidecar.sh | tail -n 1)"
fi

echo "Stopping previous HostAgent processes..." >&2
launchctl bootout "gui/$(id -u)/com.smarteffi.codexport.hostagent.p2p" >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)/${LAUNCHD_LABEL}" >/dev/null 2>&1 || true
pkill -x codexport-host-agent-menu >/dev/null 2>&1 || true
pkill -f '/codexport-host-agent --p2p-listen' >/dev/null 2>&1 || true
pkill -f '/codexport-webrtc-sidecar --stdio-jsonl' >/dev/null 2>&1 || true
pkill -f 'CodexPort WebRTC Sidecar.app/Contents/MacOS/codexport-webrtc-sidecar' >/dev/null 2>&1 || true

cat > "$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(xml_escape "$LAUNCHD_LABEL")</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/env</string>
    <string>-i</string>
    <string>PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>
    <string>HOME=$(xml_escape "$HOME")</string>
    <string>USER=$(xml_escape "${USER:-macos}")</string>
    <string>CODEXPORT_RELAY_BASE_URL=$(xml_escape "$RELAY_BASE_URL")</string>
    <string>CODEXPORT_RELAY_HOST_ID=$(xml_escape "$HOST_ID")</string>
    <string>CODEXPORT_RELAY_HOST_NAME=$(xml_escape "$HOST_NAME")</string>
    <string>CODEXPORT_RELAY_HOST_USER=$(xml_escape "$HOST_USER")</string>
    <string>CODEXPORT_CODEX_CONTROL_SOCKET_PATH=$(xml_escape "$CODEX_CONTROL_SOCKET_PATH")</string>
    <string>CODEXPORT_HOST_AGENT_P2P_LISTEN=1</string>
    <string>CODEXPORT_HOST_AGENT_BACKEND=$(xml_escape "${CODEXPORT_HOST_AGENT_BACKEND:-codex-cli-live}")</string>
    <string>CODEXPORT_WEBRTC_SIDECAR_PATH=$(xml_escape "$WEBRTC_SIDECAR_PATH")</string>
    <string>CODEXPORT_WEBRTC_SIDECAR_ARGUMENTS_JSON=$(xml_escape "$WEBRTC_SIDECAR_ARGUMENTS_JSON")</string>
    <string>$(xml_escape "$MENU_EXECUTABLE")</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$(xml_escape "$ROOT_DIR")</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>$(xml_escape "$STDOUT_LOG")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "$STDERR_LOG")</string>
</dict>
</plist>
EOF
plutil -lint "$LAUNCHD_PLIST" >/dev/null

: > "$STDOUT_LOG"
: > "$STDERR_LOG"

echo "Starting HostAgent menu LaunchAgent..." >&2
launchctl bootstrap "gui/$(id -u)" "$LAUNCHD_PLIST"
launchctl kickstart -k "gui/$(id -u)/${LAUNCHD_LABEL}"

sleep 3
PID="$(pgrep -x codexport-host-agent-menu | head -n 1 || true)"
if [[ -z "$PID" ]] || ! kill -0 "$PID" >/dev/null 2>&1; then
  echo "HostAgent menu did not stay running. stderr follows:" >&2
  tail -n 80 "$STDERR_LOG" >&2 || true
  exit 70
fi
echo "$PID" > "$PID_FILE"

echo "CODEXPORT_HOSTAGENT_MENU_PID=$PID"
echo "CODEXPORT_HOSTAGENT_MENU_STDOUT=$STDOUT_LOG"
echo "CODEXPORT_HOSTAGENT_MENU_STDERR=$STDERR_LOG"
echo "CODEXPORT_HOSTAGENT_MENU_LAUNCHD_PLIST=$LAUNCHD_PLIST"
