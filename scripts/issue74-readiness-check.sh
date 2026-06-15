#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat >&2 <<'USAGE'
Usage:
  zsh scripts/issue74-readiness-check.sh [--mode manual|local-device] [iphone-a-physical-udid] [iphone-b-physical-udid]

Checks whether the local machine is ready to run the #74 physical/TestFlight
gate. This script is read-only: it does not start HostAgent, install apps, open
deeplinks, or print secrets.

It checks:
  - required local tools
  - Codex app-server control socket
  - current HostAgent and WebRTC sidecar artifacts
  - xctrace/devicectl physical-device availability
  - active production Relay Pairing Records
  - required real-device deeplink environment variables

Optional environment:
  CODEXPORT_ISSUE74_READINESS_MODE=manual|local-device
  CODEXPORT_PHYSICAL_IPHONE_A_UDID
  CODEXPORT_PHYSICAL_IPHONE_B_UDID
  CODEXPORT_PHYSICAL_IPHONE_A_NAME
  CODEXPORT_PHYSICAL_IPHONE_B_NAME
USAGE
}

READINESS_MODE="${CODEXPORT_ISSUE74_READINESS_MODE:-manual}"
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --mode" >&2
        usage
        exit 64
      fi
      READINESS_MODE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown option: $1" >&2
      usage
      exit 64
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ "${#POSITIONAL_ARGS[@]}" -gt 2 ]]; then
  usage
  exit 64
fi

case "$READINESS_MODE" in
  manual|local-device) ;;
  *)
    echo "Invalid --mode: $READINESS_MODE" >&2
    usage
    exit 64
    ;;
esac

IPHONE_A_PHYSICAL_UDID="${POSITIONAL_ARGS[1]:-${CODEXPORT_PHYSICAL_IPHONE_A_UDID:-}}"
IPHONE_B_PHYSICAL_UDID="${POSITIONAL_ARGS[2]:-${CODEXPORT_PHYSICAL_IPHONE_B_UDID:-}}"
IPHONE_A_PHYSICAL_NAME="${CODEXPORT_PHYSICAL_IPHONE_A_NAME:-}"
IPHONE_B_PHYSICAL_NAME="${CODEXPORT_PHYSICAL_IPHONE_B_NAME:-}"
HOST_ID="${CODEXPORT_RELAY_HOST_ID:-11111111-2222-3333-4444-555555555555}"
RELAY_BASE_URL="${CODEXPORT_RELAY_BASE_URL:-https://codexport.smarteffi.net}"
CODEX_CONTROL_SOCKET_PATH="${CODEXPORT_CODEX_CONTROL_SOCKET_PATH:-$HOME/.codex/app-server-control/app-server-control.sock}"
HOSTAGENT_EXECUTABLE="${CODEXPORT_HOSTAGENT_EXECUTABLE:-$ROOT_DIR/.build/debug/codexport-host-agent}"
WEBRTC_SIDECAR_PATH="${CODEXPORT_WEBRTC_SIDECAR_PATH:-$ROOT_DIR/.scratch/webrtc-sidecar/codexport-webrtc-sidecar}"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

printf 'Mode: %s\n' "$READINESS_MODE"

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS %s\n' "$1"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf 'WARN %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL %s\n' "$1"
}

mode_fail() {
  local mode="$1"
  local message="$2"
  if [[ "$READINESS_MODE" == "$mode" ]]; then
    fail "$message"
  else
    warn "$message"
  fi
}

check_command() {
  local name="$1"
  if command -v "$name" >/dev/null; then
    pass "tool available: $name"
  else
    fail "missing tool: $name"
  fi
}

check_env_present() {
  local name="$1"
  local value="${(P)name:-}"
  if [[ -n "$value" ]]; then
    pass "environment set: $name"
  else
    fail "missing environment: $name"
  fi
}

check_command jq
check_command curl
check_command xcrun
check_command swift

if [[ -S "$CODEX_CONTROL_SOCKET_PATH" ]]; then
  pass "Codex control socket exists"
else
  fail "missing Codex control socket: $CODEX_CONTROL_SOCKET_PATH"
fi

if [[ -x "$HOSTAGENT_EXECUTABLE" ]]; then
  pass "HostAgent executable exists"
else
  warn "HostAgent executable missing; start helper will build it: $HOSTAGENT_EXECUTABLE"
fi

if [[ -x "$WEBRTC_SIDECAR_PATH" ]]; then
  pass "WebRTC sidecar exists"
else
  warn "WebRTC sidecar missing; start helper will build it: $WEBRTC_SIDECAR_PATH"
fi

XCTRACE_OUTPUT="$(xcrun xctrace list devices 2>&1 || true)"
DEVICECTL_OUTPUT="$(xcrun devicectl list devices 2>&1 || true)"

device_section_contains() {
  local section="$1"
  local udid="$2"
  awk -v section="$section" -v udid="$udid" '
    $0 == section { in_section = 1; next }
    /^==/ { in_section = 0 }
    in_section && index($0, "(" udid ")") { found = 1 }
    END { exit found ? 0 : 1 }
  ' <<<"$XCTRACE_OUTPUT"
}

check_xctrace_device() {
  local role="$1"
  local udid="$2"
  if [[ -z "$udid" ]]; then
    warn "$role physical UDID not provided"
    return
  fi
  if device_section_contains "== Devices ==" "$udid"; then
    pass "$role physical device online in xctrace"
  elif device_section_contains "== Devices Offline ==" "$udid"; then
    mode_fail local-device "$role physical device is Offline in xctrace"
  elif device_section_contains "== Simulators ==" "$udid"; then
    mode_fail local-device "$role UDID is a simulator, not a physical device"
  else
    mode_fail local-device "$role physical device not found by xctrace"
  fi
}

check_devicectl_device() {
  local role="$1"
  local udid="$2"
  local name="$3"
  if [[ -z "$udid" && -z "$name" ]]; then
    warn "$role physical UDID/name not provided for devicectl check"
    return
  fi
  local line
  if [[ -n "$udid" ]]; then
    line="$(grep -F "$udid" <<<"$DEVICECTL_OUTPUT" || true)"
  else
    line="$(awk -v name="$name" '$0 ~ "^" name "[[:space:]]" { print }' <<<"$DEVICECTL_OUTPUT" || true)"
  fi
  if [[ -z "$line" ]]; then
    warn "$role physical device not matched by devicectl; check available-device count below"
  elif grep -F "available" <<<"$line" >/dev/null; then
    pass "$role physical device available in devicectl"
  else
    mode_fail local-device "$role physical device not available in devicectl"
  fi
}

check_xctrace_device "iPhoneA" "$IPHONE_A_PHYSICAL_UDID"
check_xctrace_device "iPhoneB" "$IPHONE_B_PHYSICAL_UDID"
check_devicectl_device "iPhoneA" "$IPHONE_A_PHYSICAL_UDID" "$IPHONE_A_PHYSICAL_NAME"
check_devicectl_device "iPhoneB" "$IPHONE_B_PHYSICAL_UDID" "$IPHONE_B_PHYSICAL_NAME"

AVAILABLE_DEVICECTL_COUNT="$(awk 'index($0, "available") && !index($0, "unavailable") { count += 1 } END { print count + 0 }' <<<"$DEVICECTL_OUTPUT")"
if [[ "$AVAILABLE_DEVICECTL_COUNT" -ge 2 ]]; then
  pass "devicectl reports at least two available devices"
else
  mode_fail local-device "devicectl reports fewer than two available devices"
fi

PAIRINGS_JSON="$(mktemp "${TMPDIR:-/tmp}/codexport-issue74-pairings.XXXXXX")"
trap 'rm -f "$PAIRINGS_JSON"' EXIT

if curl -fsS "${RELAY_BASE_URL}/v0/hosts/${HOST_ID}/pairings" >"$PAIRINGS_JSON"; then
  pass "Relay pairing list reachable"
else
  fail "Relay pairing list not reachable"
  echo
  echo "Summary: ${PASS_COUNT} pass, ${WARN_COUNT} warn, ${FAIL_COUNT} fail"
  exit 1
fi

REAL_ACTIVE_PAIRING_COUNT="$(jq '
  [
    .devices[]
    | select(.revokedAtUnixTime == null)
    | select(.deviceID != "CCCCCCCC-DDDD-EEEE-FFFF-000000000001")
    | select(.deviceID != "DDDDDDDD-EEEE-FFFF-0000-000000000002")
    | select(.deviceID != "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")
  ]
  | length
' "$PAIRINGS_JSON")"
if [[ "$REAL_ACTIVE_PAIRING_COUNT" -ge 2 ]]; then
  pass "Relay has at least two non-synthetic active Pairing Records"
else
  fail "Relay has fewer than two non-synthetic active Pairing Records"
fi

check_env_present CODEXPORT_IOS_RELAY_DEVICE_ID
check_env_present CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID
check_env_present CODEXPORT_IOS_RELAY_DEVICE_ID_B
check_env_present CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID_B

check_pairing_record() {
  local role="$1"
  local device_var="$2"
  local pairing_var="$3"
  local device_id="${(P)device_var:-}"
  local pairing_record_id="${(P)pairing_var:-}"
  if [[ -z "$device_id" || -z "$pairing_record_id" ]]; then
    warn "$role Relay identity cannot be checked until $device_var and $pairing_var are set"
    return
  fi
  if jq -e --arg device_id "$device_id" --arg pairing_record_id "$pairing_record_id" '
      .devices[]
      | select(.revokedAtUnixTime == null)
      | select(.deviceID == $device_id and .pairingRecordID == $pairing_record_id)
    ' "$PAIRINGS_JSON" >/dev/null; then
    pass "$role Relay identity has active Pairing Record"
  else
    fail "$role Relay identity does not match an active Pairing Record"
  fi
}

check_pairing_record "iPhoneA" CODEXPORT_IOS_RELAY_DEVICE_ID CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID
check_pairing_record "iPhoneB" CODEXPORT_IOS_RELAY_DEVICE_ID_B CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID_B

if [[ "${CODEXPORT_ALLOW_SYNTHETIC_PAIRING_IDS:-0}" == "1" ]]; then
  fail "CODEXPORT_ALLOW_SYNTHETIC_PAIRING_IDS=1 is set; not valid for #74 close evidence"
else
  pass "synthetic Pairing IDs disabled"
fi

echo
echo "Summary: ${PASS_COUNT} pass, ${WARN_COUNT} warn, ${FAIL_COUNT} fail"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi

if [[ "$WARN_COUNT" -gt 0 ]]; then
  exit 2
fi

exit 0
