#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

source "$ROOT_DIR/scripts/lib/host-name.sh"

if [[ $# -gt 1 ]]; then
  cat >&2 <<'USAGE'
Usage:
  zsh scripts/issue74-start-hostagent-p2p.sh [run-id]

Builds the current HostAgent and WebRTC sidecar, writes a fresh run-id-scoped
LaunchAgent plist under .scratch/launchagents/, restarts HostAgent --p2p-listen,
and prints shell assignments for the run.

Source the output when a caller needs the generated values:
  eval "$(zsh scripts/issue74-start-hostagent-p2p.sh)"
USAGE
  exit 64
fi

HOST_ID="${CODEXPORT_RELAY_HOST_ID:-11111111-2222-3333-4444-555555555555}"
HOST_NAME="${CODEXPORT_RELAY_HOST_NAME:-$(codexport_default_host_name)}"
HOST_USER="${CODEXPORT_RELAY_HOST_USER:-${USER}}"
RELAY_BASE_URL="${CODEXPORT_RELAY_BASE_URL:-https://codexport.smarteffi.net}"
HOSTAGENT_LABEL="${CODEXPORT_HOSTAGENT_LAUNCHD_LABEL:-com.smarteffi.codexport.hostagent.p2p}"
HOSTAGENT_PLIST="${CODEXPORT_HOSTAGENT_LAUNCHD_PLIST:-$ROOT_DIR/.scratch/launchagents/${HOSTAGENT_LABEL}.plist}"
HOSTAGENT_STDOUT="$ROOT_DIR/.scratch/logs/hostagent-p2p-launchd.out"
HOSTAGENT_STDERR="$ROOT_DIR/.scratch/logs/hostagent-p2p-launchd.err"
HOSTAGENT_EXECUTABLE="${CODEXPORT_HOSTAGENT_EXECUTABLE:-$ROOT_DIR/.build/debug/codexport-host-agent}"
HOSTAGENT_RUN_ID="${1:-${CODEXPORT_ISSUE74_RUN_ID:-issue74-hostagent-$(date +%Y%m%d%H%M%S)-$$}}"
CODEX_CONTROL_SOCKET_PATH="${CODEXPORT_CODEX_CONTROL_SOCKET_PATH:-$HOME/.codex/app-server-control/app-server-control.sock}"
WEBRTC_SIDECAR_DEFAULT_PATH="$ROOT_DIR/.scratch/webrtc-sidecar/CodexPort WebRTC Sidecar.app/Contents/MacOS/codexport-webrtc-sidecar"
WEBRTC_SIDECAR_PATH="${CODEXPORT_WEBRTC_SIDECAR_PATH:-$WEBRTC_SIDECAR_DEFAULT_PATH}"
WEBRTC_SIDECAR_ARGUMENTS_JSON="${CODEXPORT_WEBRTC_SIDECAR_ARGUMENTS_JSON:-[\"--stdio-jsonl\"]}"

if [[ ! -S "$CODEX_CONTROL_SOCKET_PATH" ]]; then
  echo "Missing Codex control socket: $CODEX_CONTROL_SOCKET_PATH" >&2
  echo "Open Codex TUI on the target thread before starting HostAgent P2P." >&2
  exit 69
fi

mkdir -p "$ROOT_DIR/.scratch/logs"
mkdir -p "$(dirname "$HOSTAGENT_PLIST")"

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

write_hostagent_launchagent_plist() {
  local environment_args=(
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
    "CODEXPORT_RELAY_BASE_URL=$RELAY_BASE_URL"
    "CODEXPORT_RELAY_HOST_ID=$HOST_ID"
    "CODEXPORT_RELAY_HOST_NAME=$HOST_NAME"
    "CODEXPORT_RELAY_HOST_USER=$HOST_USER"
    "CODEXPORT_CODEX_CONTROL_SOCKET_PATH=$CODEX_CONTROL_SOCKET_PATH"
    "CODEXPORT_WEBRTC_SIDECAR_PATH=$WEBRTC_SIDECAR_PATH"
    "CODEXPORT_WEBRTC_SIDECAR_ARGUMENTS_JSON=$WEBRTC_SIDECAR_ARGUMENTS_JSON"
    "CODEXPORT_ISSUE74_RUN_ID=$HOSTAGENT_RUN_ID"
  )

  for optional_name in \
    CODEXPORT_HOST_AGENT_BACKEND \
    CODEXPORT_WEBRTC_ICE_SERVERS_JSON \
    CODEXPORT_WEBRTC_STUN_URLS \
    CODEXPORT_WEBRTC_TURN_URLS \
    CODEXPORT_WEBRTC_TURN_USERNAME \
    CODEXPORT_WEBRTC_TURN_CREDENTIAL
  do
    local optional_value="${(P)optional_name:-}"
    if [[ -n "$optional_value" ]]; then
      environment_args+=("${optional_name}=${optional_value}")
    fi
  done

  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0">'
    echo '<dict>'
    echo '  <key>Label</key>'
    printf '  <string>%s</string>\n' "$(xml_escape "$HOSTAGENT_LABEL")"
    echo '  <key>ProgramArguments</key>'
    echo '  <array>'
    echo '    <string>/usr/bin/env</string>'
    echo '    <string>-i</string>'
    for argument in "${environment_args[@]}"; do
      printf '    <string>%s</string>\n' "$(xml_escape "$argument")"
    done
    printf '    <string>%s</string>\n' "$(xml_escape "$HOSTAGENT_EXECUTABLE")"
    echo '    <string>--p2p-listen</string>'
    echo '  </array>'
    echo '  <key>WorkingDirectory</key>'
    printf '  <string>%s</string>\n' "$(xml_escape "$ROOT_DIR")"
    echo '  <key>RunAtLoad</key>'
    echo '  <true/>'
    echo '  <key>KeepAlive</key>'
    echo '  <false/>'
    echo '  <key>StandardOutPath</key>'
    printf '  <string>%s</string>\n' "$(xml_escape "$HOSTAGENT_STDOUT")"
    echo '  <key>StandardErrorPath</key>'
    printf '  <string>%s</string>\n' "$(xml_escape "$HOSTAGENT_STDERR")"
    echo '</dict>'
    echo '</plist>'
  } > "$HOSTAGENT_PLIST"
  plutil -lint "$HOSTAGENT_PLIST" >/dev/null
}

echo "Building HostAgent..." >&2
swift build --product codexport-host-agent >&2

if [[ "${CODEXPORT_SKIP_WEBRTC_SIDECAR_BUILD:-0}" != "1" ]]; then
  echo "Building WebRTC sidecar..." >&2
  WEBRTC_SIDECAR_PATH="$(scripts/build-webrtc-sidecar.sh | tail -n 1)"
fi

write_hostagent_launchagent_plist

echo "Restarting HostAgent LaunchAgent..." >&2
launchctl bootout "gui/$(id -u)/${HOSTAGENT_LABEL}" 2>/dev/null || true
: > "$HOSTAGENT_STDOUT"
: > "$HOSTAGENT_STDERR"
launchctl bootstrap "gui/$(id -u)" "$HOSTAGENT_PLIST"
launchctl kickstart -k "gui/$(id -u)/${HOSTAGENT_LABEL}"
sleep 4

if ! pgrep -fl 'codexport-host-agent --p2p-listen' >/dev/null; then
  echo "HostAgent did not stay running. stderr follows:" >&2
  tail -n 80 "$HOSTAGENT_STDERR" >&2 || true
  exit 70
fi

STATUS_CODE="$(curl -sS -o /tmp/codexport-issue74-p2p-state.json -w '%{http_code}' "${RELAY_BASE_URL}/v0/p2p/hosts/${HOST_ID}/messages")"
if [[ "$STATUS_CODE" != "200" ]]; then
  echo "Relay P2P host drain returned HTTP $STATUS_CODE" >&2
  cat /tmp/codexport-issue74-p2p-state.json >&2 || true
  exit 69
fi

printf 'CODEXPORT_ISSUE74_RUN_ID=%q\n' "$HOSTAGENT_RUN_ID"
printf 'CODEXPORT_HOSTAGENT_STDOUT=%q\n' "$HOSTAGENT_STDOUT"
printf 'CODEXPORT_HOSTAGENT_STDERR=%q\n' "$HOSTAGENT_STDERR"
printf 'CODEXPORT_HOSTAGENT_LAUNCHD_PLIST=%q\n' "$HOSTAGENT_PLIST"
