#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  cat >&2 <<'USAGE'
Usage:
  zsh scripts/issue74-idle-tui-sim-smoke.sh <idle-thread-id> [marker]

Runs the simulator-side #74 idle TUI smoke:
  - builds the current HostAgent and WebRTC sidecar
  - restarts the HostAgent P2P LaunchAgent
  - builds and installs the app on iPhoneA and iPhoneB simulators
  - launches iPhoneB first as an observer on CODEXPORT_IOS_RELAY_THREAD_ID
  - launches iPhoneA second and sends CODEXPORT_IOS_RELAY_AUTOPROMPT

Open the same idle thread in Codex TUI before running this script.
By default this script uses the visible iPhone 17 Pro simulator only. Set
CODEXPORT_IPHONE_B_SIMULATOR_ID explicitly when intentionally running a second
simulator device.
To list metadata-only candidate idle threads first:
  zsh scripts/issue74-list-idle-threads.sh [limit]
USAGE
  exit 64
fi

THREAD_ID="$1"
MARKER="${2:-ISSUE74-IDLE-TUI-$(date +%Y%m%d%H%M%S)}"

HOST_ID="${CODEXPORT_RELAY_HOST_ID:-11111111-2222-3333-4444-555555555555}"
HOST_NAME="${CODEXPORT_RELAY_HOST_NAME:-CodexPort Dev Mac}"
HOST_USER="${CODEXPORT_RELAY_HOST_USER:-${USER}}"
RELAY_BASE_URL="${CODEXPORT_RELAY_BASE_URL:-https://codexport.smarteffi.net}"
RELAY_ENDPOINT_URL="${CODEXPORT_IOS_RELAY_ENDPOINT_URL:-wss://codexport.smarteffi.net/v0/streams}"
IPHONE_A_DEVICE_ID="${CODEXPORT_IOS_RELAY_DEVICE_ID:-CCCCCCCC-DDDD-EEEE-FFFF-000000000001}"
IPHONE_A_PAIRING_RECORD_ID="${CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID:-pairing-${HOST_ID}-${IPHONE_A_DEVICE_ID}}"
IPHONE_B_DEVICE_ID="${CODEXPORT_IOS_RELAY_DEVICE_ID_B:-DDDDDDDD-EEEE-FFFF-0000-000000000002}"
IPHONE_B_PAIRING_RECORD_ID="${CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID_B:-pairing-${HOST_ID}-${IPHONE_B_DEVICE_ID}}"
IPHONE_A_SIMULATOR_ID="${CODEXPORT_SIMULATOR_ID:-${CODEXPORT_IPHONE_A_SIMULATOR_ID:-605E6C0B-D682-4AF8-98B6-6B344715D561}}"
IPHONE_B_SIMULATOR_ID="${CODEXPORT_IPHONE_B_SIMULATOR_ID:-}"
BUNDLE_ID="${CODEXPORT_IOS_BUNDLE_ID:-com.smarteffi.codexport}"
PROJECT_PATH="${CODEXPORT_XCODE_PROJECT:-CodexPort.xcodeproj}"
SCHEME="${CODEXPORT_XCODE_SCHEME:-CodexPort}"
CONFIGURATION="${CODEXPORT_XCODE_CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${CODEXPORT_DERIVED_DATA_PATH:-$ROOT_DIR/.scratch/DerivedData/Issue74IdleTUISmoke}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}-iphonesimulator/CodexPort.app"
HOSTAGENT_RUN_ID="${CODEXPORT_ISSUE74_RUN_ID:-issue74-sim-$(date +%Y%m%d%H%M%S)-$$}"
CODEX_CONTROL_SOCKET_PATH="${CODEXPORT_CODEX_CONTROL_SOCKET_PATH:-$HOME/.codex/app-server-control/app-server-control.sock}"
VERIFY_TIMEOUT_SECONDS="${CODEXPORT_ISSUE74_VERIFY_TIMEOUT_SECONDS:-180}"
VERIFY_INTERVAL_SECONDS="${CODEXPORT_ISSUE74_VERIFY_INTERVAL_SECONDS:-5}"

if [[ ! -S "$CODEX_CONTROL_SOCKET_PATH" ]]; then
  echo "Missing Codex control socket: $CODEX_CONTROL_SOCKET_PATH" >&2
  echo "Open Codex TUI on the target thread before running this smoke." >&2
  exit 69
fi

if [[ -z "$IPHONE_B_SIMULATOR_ID" ]]; then
  CODEXPORT_SKIP_IPHONE_B_OBSERVER="${CODEXPORT_SKIP_IPHONE_B_OBSERVER:-1}"
fi

eval "$(zsh scripts/issue74-start-hostagent-p2p.sh "$HOSTAGENT_RUN_ID")"
HOSTAGENT_STDOUT="$CODEXPORT_HOSTAGENT_STDOUT"

echo "Building iOS simulator app..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk iphonesimulator \
  -destination "id=${IPHONE_A_SIMULATOR_ID}" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

launch_simulator_client() {
  local simulator_id="$1"
  local device_id="$2"
  local pairing_record_id="$3"
  local role="$4"
  local autoprompt="${5:-}"

  echo "Installing and launching ${role} (${simulator_id})..."
  xcrun simctl boot "$simulator_id" 2>/dev/null || true
  xcrun simctl bootstatus "$simulator_id" -b
  xcrun simctl terminate "$simulator_id" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl install "$simulator_id" "$APP_PATH"

  local launch_env=(
    SIMCTL_CHILD_CODEXPORT_IOS_RELAY_HOST_ID="$HOST_ID"
    SIMCTL_CHILD_CODEXPORT_IOS_RELAY_HOST_NAME="$HOST_NAME"
    SIMCTL_CHILD_CODEXPORT_IOS_RELAY_HOST_USER="$HOST_USER"
    SIMCTL_CHILD_CODEXPORT_IOS_RELAY_DEVICE_ID="$device_id"
    SIMCTL_CHILD_CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID="$pairing_record_id"
    SIMCTL_CHILD_CODEXPORT_IOS_RELAY_ENDPOINT_URL="$RELAY_ENDPOINT_URL"
    SIMCTL_CHILD_CODEXPORT_IOS_RELAY_DEFAULT_DIRECTORY="$ROOT_DIR"
    SIMCTL_CHILD_CODEXPORT_IOS_RELAY_TRANSPORT_MODE="p2p-webrtc-datachannel"
    SIMCTL_CHILD_CODEXPORT_IOS_RELAY_AUTOCONNECT="1"
    SIMCTL_CHILD_CODEXPORT_IOS_RELAY_THREAD_ID="$THREAD_ID"
  )

  if [[ -n "$autoprompt" ]]; then
    launch_env+=(SIMCTL_CHILD_CODEXPORT_IOS_RELAY_AUTOPROMPT="$autoprompt")
  fi

  env "${launch_env[@]}" xcrun simctl launch --terminate-running-process "$simulator_id" "$BUNDLE_ID"
}

if [[ "${CODEXPORT_SKIP_IPHONE_B_OBSERVER:-0}" != "1" ]]; then
  if [[ -z "$IPHONE_B_SIMULATOR_ID" ]]; then
    echo "CODEXPORT_IPHONE_B_SIMULATOR_ID is required when CODEXPORT_SKIP_IPHONE_B_OBSERVER is not 1." >&2
    exit 64
  fi
  launch_simulator_client "$IPHONE_B_SIMULATOR_ID" "$IPHONE_B_DEVICE_ID" "$IPHONE_B_PAIRING_RECORD_ID" "iPhoneB observer" ""
  sleep 3
fi

launch_simulator_client "$IPHONE_A_SIMULATOR_ID" "$IPHONE_A_DEVICE_ID" "$IPHONE_A_PAIRING_RECORD_ID" "iPhoneA sender" "$MARKER"

echo
echo "Launched #74 idle TUI simulator smoke."
echo "Thread: $THREAD_ID"
echo "Marker: $MARKER"
echo "HostAgent run id: $HOSTAGENT_RUN_ID"
echo "iPhoneA simulator: $IPHONE_A_SIMULATOR_ID"
echo "iPhoneB simulator: ${IPHONE_B_SIMULATOR_ID:-skipped}"
echo "HostAgent stdout: $HOSTAGENT_STDOUT"
echo
echo "Expected HostAgent evidence, without prompt plaintext:"
echo "  type=prompt thread=$THREAD_ID"
if [[ "${CODEXPORT_SKIP_IPHONE_B_OBSERVER:-0}" == "1" ]]; then
  echo "  single visible simulator rehearsal only; two-client verifier is skipped"
else
  echo "  two distinct client=pairing-* entries attached to thread=$THREAD_ID"
fi
echo "  event=writeStatusChanged status=handled"
echo "  event=userMessage"
echo "  event=turnCompleted"
echo "  event=assistantTextDelta"
echo
echo "Suggested check:"
echo "  zsh scripts/issue74-verify-hostagent-log.sh \\"
echo "    '$THREAD_ID' \\"
echo "    '$HOSTAGENT_STDOUT' \\"
echo "    --run-id '$HOSTAGENT_RUN_ID' \\"
echo "    --sender-client '$IPHONE_A_PAIRING_RECORD_ID' \\"
echo "    --observer-client '$IPHONE_B_PAIRING_RECORD_ID' \\"
echo "    --forbid-text '<marker>'"

if [[ "${CODEXPORT_SKIP_ISSUE74_VERIFY:-0}" == "1" || "${CODEXPORT_SKIP_IPHONE_B_OBSERVER:-0}" == "1" ]]; then
  exit 0
fi

echo
echo "Waiting for metadata gate verification..."
deadline=$((SECONDS + VERIFY_TIMEOUT_SECONDS))
last_output=""
while (( SECONDS <= deadline )); do
  set +e
  last_output="$(zsh scripts/issue74-verify-hostagent-log.sh "$THREAD_ID" "$HOSTAGENT_STDOUT" --run-id "$HOSTAGENT_RUN_ID" --sender-client "$IPHONE_A_PAIRING_RECORD_ID" --observer-client "$IPHONE_B_PAIRING_RECORD_ID" --forbid-text "$MARKER" 2>&1)"
  verify_status=$?
  set -e
  if [[ "$verify_status" -eq 0 ]]; then
    echo "$last_output"
    exit 0
  fi
  sleep "$VERIFY_INTERVAL_SECONDS"
done

echo "$last_output"
echo
echo "Issue #74 idle TUI simulator smoke timed out after ${VERIFY_TIMEOUT_SECONDS}s." >&2
exit 1
