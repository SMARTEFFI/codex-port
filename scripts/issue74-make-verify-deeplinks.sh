#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

source "$SCRIPT_ROOT/scripts/lib/host-name.sh"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  cat >&2 <<'USAGE'
Usage:
  zsh scripts/issue74-make-verify-deeplinks.sh <idle-thread-id> [marker]

Prints TestFlight/manual verification deeplinks for iPhoneA and iPhoneB.
These URLs contain pairing record metadata and the target thread id; they do
not contain Pairing Token, Codex token, prompt history, assistant output, or
other secrets.

Required for real-device/TestFlight runs:
  CODEXPORT_IOS_RELAY_DEVICE_ID
  CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID
  CODEXPORT_IOS_RELAY_DEVICE_ID_B
  CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID_B

Use values from the production Relay pairing-record list for the two real
iPhones. Set CODEXPORT_ALLOW_SYNTHETIC_PAIRING_IDS=1 only for simulator/dev
rehearsal with the fixed synthetic identities.
USAGE
  exit 64
fi

THREAD_ID="$1"
MARKER="${2:-ISSUE74-PHYSICAL-IDLE-TUI-$(date +%Y%m%d%H%M%S)}"

HOST_ID="${CODEXPORT_RELAY_HOST_ID:-11111111-2222-3333-4444-555555555555}"
HOST_NAME="${CODEXPORT_RELAY_HOST_NAME:-$(codexport_default_host_name)}"
HOST_USER="${CODEXPORT_RELAY_HOST_USER:-${USER}}"
RELAY_ENDPOINT_URL="${CODEXPORT_IOS_RELAY_ENDPOINT_URL:-wss://codexport.smarteffi.net/v0/streams}"
DEFAULT_DIRECTORY="${CODEXPORT_IOS_RELAY_DEFAULT_DIRECTORY:-$PWD}"

require_env() {
  local name="$1"
  local value="${(P)name:-}"
  if [[ -z "$value" ]]; then
    echo "Missing required environment variable for real-device deeplink: $name" >&2
    echo "Fetch active pairing records from the HostAgent/Relay pairing list and export the real device id + pairing record id." >&2
    exit 64
  fi
  printf '%s' "$value"
}

if [[ "${CODEXPORT_ALLOW_SYNTHETIC_PAIRING_IDS:-0}" == "1" ]]; then
  IPHONE_A_DEVICE_ID="${CODEXPORT_IOS_RELAY_DEVICE_ID:-CCCCCCCC-DDDD-EEEE-FFFF-000000000001}"
  IPHONE_A_PAIRING_RECORD_ID="${CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID:-pairing-${HOST_ID}-${IPHONE_A_DEVICE_ID}}"
  IPHONE_B_DEVICE_ID="${CODEXPORT_IOS_RELAY_DEVICE_ID_B:-DDDDDDDD-EEEE-FFFF-0000-000000000002}"
  IPHONE_B_PAIRING_RECORD_ID="${CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID_B:-pairing-${HOST_ID}-${IPHONE_B_DEVICE_ID}}"
else
  IPHONE_A_DEVICE_ID="$(require_env CODEXPORT_IOS_RELAY_DEVICE_ID)"
  IPHONE_A_PAIRING_RECORD_ID="$(require_env CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID)"
  IPHONE_B_DEVICE_ID="$(require_env CODEXPORT_IOS_RELAY_DEVICE_ID_B)"
  IPHONE_B_PAIRING_RECORD_ID="$(require_env CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID_B)"
fi

if ! command -v jq >/dev/null; then
  echo "Missing jq; required to URL-encode deeplink query values." >&2
  exit 69
fi

urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
}

make_url() {
  local device_id="$1"
  local pairing_record_id="$2"
  local autoprompt="$3"

  printf 'codexport://verify?hostID=%s&hostName=%s&hostUser=%s&deviceID=%s&pairingRecordID=%s&endpointURL=%s&defaultDirectory=%s&threadID=%s' \
    "$(urlencode "$HOST_ID")" \
    "$(urlencode "$HOST_NAME")" \
    "$(urlencode "$HOST_USER")" \
    "$(urlencode "$device_id")" \
    "$(urlencode "$pairing_record_id")" \
    "$(urlencode "$RELAY_ENDPOINT_URL")" \
    "$(urlencode "$DEFAULT_DIRECTORY")" \
    "$(urlencode "$THREAD_ID")"

  if [[ -n "$autoprompt" ]]; then
    printf '&autoprompt=%s' "$(urlencode "$autoprompt")"
  fi
  printf '\n'
}

echo "iPhoneB observer deeplink:"
make_url "$IPHONE_B_DEVICE_ID" "$IPHONE_B_PAIRING_RECORD_ID" ""
echo
echo "iPhoneA sender deeplink:"
make_url "$IPHONE_A_DEVICE_ID" "$IPHONE_A_PAIRING_RECORD_ID" "$MARKER"
echo
echo "Marker: $MARKER"
