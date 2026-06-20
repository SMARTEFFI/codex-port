#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

source "$ROOT_DIR/scripts/lib/host-name.sh"

if [[ $# -lt 3 || $# -gt 4 ]]; then
  cat >&2 <<'USAGE'
Usage:
  zsh scripts/issue74-idle-tui-device-smoke.sh <idle-thread-id> <iphone-a-physical-device-udid> <iphone-b-physical-device-udid> [marker]

Runs the physical-device #74 idle TUI smoke:
  - requires both physical devices to be online in xcrun xctrace list devices
  - builds the current HostAgent and WebRTC sidecar
  - restarts the HostAgent P2P LaunchAgent
  - builds the iOS app for iphoneos
  - installs and launches the app on iPhoneB first as observer
  - installs and launches the app on iPhoneA second with CODEXPORT_IOS_RELAY_AUTOPROMPT
  - waits for metadata-only HostAgent log verification

Open the same idle thread in Codex TUI before running this script.
To list metadata-only candidate idle threads first:
  zsh scripts/issue74-list-idle-threads.sh [limit]

This helper passes a JSON environment object to devicectl launch. It is for
locally available, trusted physical devices; TestFlight/manual runs should use
the same HostAgent log verifier after pairing both devices in the UI.

Required for real-device evidence:
  CODEXPORT_IOS_RELAY_DEVICE_ID
  CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID
  CODEXPORT_IOS_RELAY_DEVICE_ID_B
  CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID_B

Set CODEXPORT_ALLOW_SYNTHETIC_PAIRING_IDS=1 only for local/dev rehearsal with
synthetic Relay identities. Synthetic identities are not #74 close evidence.
USAGE
  exit 64
fi

THREAD_ID="$1"
PHYSICAL_IPHONE_A_DEVICE_ID="$2"
PHYSICAL_IPHONE_B_DEVICE_ID="$3"
MARKER="${4:-ISSUE74-PHYSICAL-IDLE-TUI-$(date +%Y%m%d%H%M%S)}"

HOST_ID="${CODEXPORT_RELAY_HOST_ID:-11111111-2222-3333-4444-555555555555}"
HOST_NAME="${CODEXPORT_RELAY_HOST_NAME:-$(codexport_default_host_name)}"
HOST_USER="${CODEXPORT_RELAY_HOST_USER:-${USER}}"
RELAY_BASE_URL="${CODEXPORT_RELAY_BASE_URL:-https://codexport.smarteffi.net}"
RELAY_ENDPOINT_URL="${CODEXPORT_IOS_RELAY_ENDPOINT_URL:-wss://codexport.smarteffi.net/v0/streams}"
BUNDLE_ID="${CODEXPORT_IOS_BUNDLE_ID:-com.smarteffi.codexport}"
PROJECT_PATH="${CODEXPORT_XCODE_PROJECT:-CodexPort.xcodeproj}"
SCHEME="${CODEXPORT_XCODE_SCHEME:-CodexPort}"
CONFIGURATION="${CODEXPORT_XCODE_CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${CODEXPORT_DERIVED_DATA_PATH:-$ROOT_DIR/.scratch/DerivedData/Issue74IdleTUIDeviceSmoke}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}-iphoneos/CodexPort.app"
HOSTAGENT_RUN_ID="${CODEXPORT_ISSUE74_RUN_ID:-issue74-device-$(date +%Y%m%d%H%M%S)-$$}"
CODEX_CONTROL_SOCKET_PATH="${CODEXPORT_CODEX_CONTROL_SOCKET_PATH:-$HOME/.codex/app-server-control/app-server-control.sock}"
VERIFY_TIMEOUT_SECONDS="${CODEXPORT_ISSUE74_VERIFY_TIMEOUT_SECONDS:-240}"
VERIFY_INTERVAL_SECONDS="${CODEXPORT_ISSUE74_VERIFY_INTERVAL_SECONDS:-5}"

require_real_relay_identity() {
  local name="$1"
  local value="${(P)name:-}"
  if [[ -z "$value" ]]; then
    echo "Missing required environment variable for physical-device #74 evidence: $name" >&2
    echo "Pair both real iPhones first, then export their Relay device IDs and Pairing Record IDs." >&2
    echo "Use zsh scripts/issue74-list-pairing-records.sh to list active Pairing Record metadata." >&2
    echo "Set CODEXPORT_ALLOW_SYNTHETIC_PAIRING_IDS=1 only for local/dev rehearsal, not close evidence." >&2
    exit 64
  fi
  printf '%s' "$value"
}

if [[ "${CODEXPORT_ALLOW_SYNTHETIC_PAIRING_IDS:-0}" == "1" ]]; then
  IPHONE_A_RELAY_DEVICE_ID="${CODEXPORT_IOS_RELAY_DEVICE_ID:-CCCCCCCC-DDDD-EEEE-FFFF-000000000001}"
  IPHONE_A_PAIRING_RECORD_ID="${CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID:-pairing-${HOST_ID}-${IPHONE_A_RELAY_DEVICE_ID}}"
  IPHONE_B_RELAY_DEVICE_ID="${CODEXPORT_IOS_RELAY_DEVICE_ID_B:-DDDDDDDD-EEEE-FFFF-0000-000000000002}"
  IPHONE_B_PAIRING_RECORD_ID="${CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID_B:-pairing-${HOST_ID}-${IPHONE_B_RELAY_DEVICE_ID}}"
else
  IPHONE_A_RELAY_DEVICE_ID="$(require_real_relay_identity CODEXPORT_IOS_RELAY_DEVICE_ID)"
  IPHONE_A_PAIRING_RECORD_ID="$(require_real_relay_identity CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID)"
  IPHONE_B_RELAY_DEVICE_ID="$(require_real_relay_identity CODEXPORT_IOS_RELAY_DEVICE_ID_B)"
  IPHONE_B_PAIRING_RECORD_ID="$(require_real_relay_identity CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID_B)"
fi

if [[ ! -S "$CODEX_CONTROL_SOCKET_PATH" ]]; then
  echo "Missing Codex control socket: $CODEX_CONTROL_SOCKET_PATH" >&2
  echo "Open Codex TUI on the target thread before running this smoke." >&2
  exit 69
fi

if ! command -v jq >/dev/null; then
  echo "Missing jq; required to build devicectl launch environment JSON." >&2
  exit 69
fi

ensure_physical_device_online() {
  local physical_device_id="$1"
  local role="$2"
  local device_list
  device_list="$(xcrun xctrace list devices)"

  if ! grep -F "(${physical_device_id})" <<<"$device_list" >/dev/null; then
    echo "${role} physical device not found by xctrace: ${physical_device_id}" >&2
    echo "$device_list" >&2
    exit 69
  fi

  if awk '/^== Devices Offline ==/{offline=1; next} /^==/{offline=0} offline{print}' <<<"$device_list" \
    | grep -F "(${physical_device_id})" >/dev/null; then
    echo "${role} physical device is Offline: ${physical_device_id}" >&2
    echo "$device_list" >&2
    exit 69
  fi

  if awk '/^== Simulators ==/{simulator=1; next} /^==/{simulator=0} simulator{print}' <<<"$device_list" \
    | grep -F "(${physical_device_id})" >/dev/null; then
    echo "${role} must be a physical device, got simulator id: ${physical_device_id}" >&2
    exit 64
  fi
}

ensure_devicectl_available() {
  local output_file="/tmp/codexport-issue74-devicectl-health.txt"
  if ! xcrun devicectl list devices >"$output_file" 2>&1; then
    local status=$?
    echo "devicectl health check failed with exit ${status}." >&2
    echo "This physical-device helper requires a working xcrun devicectl." >&2
    cat "$output_file" >&2 || true
    exit 69
  fi
}

ensure_physical_device_online "$PHYSICAL_IPHONE_A_DEVICE_ID" "iPhoneA"
ensure_physical_device_online "$PHYSICAL_IPHONE_B_DEVICE_ID" "iPhoneB"
ensure_devicectl_available

eval "$(zsh scripts/issue74-start-hostagent-p2p.sh "$HOSTAGENT_RUN_ID")"
HOSTAGENT_STDOUT="$CODEXPORT_HOSTAGENT_STDOUT"

echo "Building iOS app for physical device..."
xcodebuild_args=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -sdk iphoneos
  -destination "id=${PHYSICAL_IPHONE_A_DEVICE_ID}"
  -derivedDataPath "$DERIVED_DATA_PATH"
)

if [[ "${CODEXPORT_XCODE_ALLOW_PROVISIONING_UPDATES:-0}" == "1" ]]; then
  xcodebuild_args+=(-allowProvisioningUpdates)
fi

if [[ -n "${CODEXPORT_XCODE_DEVELOPMENT_TEAM:-}" ]]; then
  xcodebuild_args+=("DEVELOPMENT_TEAM=${CODEXPORT_XCODE_DEVELOPMENT_TEAM}" "CODE_SIGN_STYLE=Automatic")
fi

xcodebuild "${xcodebuild_args[@]}" build

launch_physical_client() {
  local physical_device_id="$1"
  local relay_device_id="$2"
  local pairing_record_id="$3"
  local role="$4"
  local autoprompt="${5:-}"

  echo "Installing and launching ${role} (${physical_device_id})..."
  xcrun devicectl device install app --device "$physical_device_id" "$APP_PATH"

  local launch_environment
  launch_environment="$(jq -cn \
    --arg host_id "$HOST_ID" \
    --arg host_name "$HOST_NAME" \
    --arg host_user "$HOST_USER" \
    --arg relay_device_id "$relay_device_id" \
    --arg pairing_record_id "$pairing_record_id" \
    --arg relay_endpoint_url "$RELAY_ENDPOINT_URL" \
    --arg default_directory "$ROOT_DIR" \
    --arg thread_id "$THREAD_ID" \
    --arg autoprompt "$autoprompt" \
    '
      {
        CODEXPORT_IOS_RELAY_HOST_ID: $host_id,
        CODEXPORT_IOS_RELAY_HOST_NAME: $host_name,
        CODEXPORT_IOS_RELAY_HOST_USER: $host_user,
        CODEXPORT_IOS_RELAY_DEVICE_ID: $relay_device_id,
        CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID: $pairing_record_id,
        CODEXPORT_IOS_RELAY_ENDPOINT_URL: $relay_endpoint_url,
        CODEXPORT_IOS_RELAY_DEFAULT_DIRECTORY: $default_directory,
        CODEXPORT_IOS_RELAY_TRANSPORT_MODE: "p2p-webrtc-datachannel",
        CODEXPORT_IOS_RELAY_AUTOCONNECT: "1",
        CODEXPORT_IOS_RELAY_THREAD_ID: $thread_id
      }
      + if $autoprompt == "" then {} else {CODEXPORT_IOS_RELAY_AUTOPROMPT: $autoprompt} end
    '
  )"

  xcrun devicectl device process launch \
    --device "$physical_device_id" \
    --terminate-existing \
    --environment-variables "$launch_environment" \
    "$BUNDLE_ID"
}

launch_physical_client "$PHYSICAL_IPHONE_B_DEVICE_ID" "$IPHONE_B_RELAY_DEVICE_ID" "$IPHONE_B_PAIRING_RECORD_ID" "iPhoneB observer" ""
sleep 3
launch_physical_client "$PHYSICAL_IPHONE_A_DEVICE_ID" "$IPHONE_A_RELAY_DEVICE_ID" "$IPHONE_A_PAIRING_RECORD_ID" "iPhoneA sender" "$MARKER"

echo
echo "Launched #74 idle TUI physical-device smoke."
echo "Thread: $THREAD_ID"
echo "Marker: $MARKER"
echo "HostAgent run id: $HOSTAGENT_RUN_ID"
echo "iPhoneA physical device: $PHYSICAL_IPHONE_A_DEVICE_ID"
echo "iPhoneB physical device: $PHYSICAL_IPHONE_B_DEVICE_ID"
echo "iPhoneA relay device identity: $IPHONE_A_RELAY_DEVICE_ID"
echo "iPhoneB relay device identity: $IPHONE_B_RELAY_DEVICE_ID"
echo "HostAgent stdout: $HOSTAGENT_STDOUT"

if [[ "${CODEXPORT_SKIP_ISSUE74_VERIFY:-0}" == "1" ]]; then
  exit 0
fi

echo
echo "Waiting for metadata gate verification..."
deadline=$((SECONDS + VERIFY_TIMEOUT_SECONDS))
last_output=""
while (( SECONDS <= deadline )); do
  set +e
  last_output="$(zsh scripts/issue74-verify-hostagent-log.sh "$THREAD_ID" "$HOSTAGENT_STDOUT" --run-id "$HOSTAGENT_RUN_ID" --sender-client "$IPHONE_A_PAIRING_RECORD_ID" --observer-client "$IPHONE_B_PAIRING_RECORD_ID" --forbid-text "$MARKER" 2>&1)"
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    echo "$last_output"
    exit 0
  fi
  sleep "$VERIFY_INTERVAL_SECONDS"
done

echo "$last_output"
echo
echo "Issue #74 idle TUI physical-device smoke timed out after ${VERIFY_TIMEOUT_SECONDS}s." >&2
exit 1
