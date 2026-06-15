#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat >&2 <<'USAGE'
Usage:
  zsh scripts/issue74-export-real-pairing-env.sh --list
  zsh scripts/issue74-export-real-pairing-env.sh --iphone-a <device-id|pairing-record-id|display-name-substring> --iphone-b <device-id|pairing-record-id|display-name-substring>
  zsh scripts/issue74-export-real-pairing-env.sh --auto-two

Prints shell exports for the four real-device Relay identity variables needed
by the #74 TestFlight/manual gate:
  CODEXPORT_IOS_RELAY_DEVICE_ID
  CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID
  CODEXPORT_IOS_RELAY_DEVICE_ID_B
  CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID_B

The script is read-only. It fetches Pairing Record metadata from Relay unless
--pairings-file is provided, excludes the fixed simulator/smoke identities, and
never prints Pairing Tokens, Codex tokens, prompt history, assistant output, or
credentials.

Options:
  --list                 Print active non-synthetic Pairing Record metadata.
  --iphone-a <selector>  Select the sender phone by device id, pairing record
                         id, or case-insensitive display-name substring.
  --iphone-b <selector>  Select the observer phone by device id, pairing record
                         id, or case-insensitive display-name substring.
  --auto-two             If exactly two active non-synthetic records exist,
                         assign them in stable sorted order.
  --pairings-file <path> Read pairings JSON from a local file for tests.
  --help                 Show this help.

Example:
  eval "$(zsh scripts/issue74-export-real-pairing-env.sh --iphone-a min --iphone-b pie)"
USAGE
}

HOST_ID="${CODEXPORT_RELAY_HOST_ID:-11111111-2222-3333-4444-555555555555}"
RELAY_BASE_URL="${CODEXPORT_RELAY_BASE_URL:-https://codexport.smarteffi.net}"
LIST_ONLY=0
AUTO_TWO=0
IPHONE_A_SELECTOR=""
IPHONE_B_SELECTOR=""
PAIRINGS_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      LIST_ONLY=1
      shift
      ;;
    --auto-two)
      AUTO_TWO=1
      shift
      ;;
    --iphone-a)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --iphone-a" >&2
        usage
        exit 64
      fi
      IPHONE_A_SELECTOR="$2"
      shift 2
      ;;
    --iphone-b)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --iphone-b" >&2
        usage
        exit 64
      fi
      IPHONE_B_SELECTOR="$2"
      shift 2
      ;;
    --pairings-file)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --pairings-file" >&2
        usage
        exit 64
      fi
      PAIRINGS_FILE="$2"
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
      echo "Unexpected argument: $1" >&2
      usage
      exit 64
      ;;
  esac
done

if ! command -v jq >/dev/null; then
  echo "Missing jq; required to read Pairing Record metadata." >&2
  exit 69
fi

TEMP_FILES=()
cleanup() {
  if [[ "${#TEMP_FILES[@]}" -gt 0 ]]; then
    rm -f "${TEMP_FILES[@]}"
  fi
}
trap cleanup EXIT

if [[ -n "$PAIRINGS_FILE" ]]; then
  if [[ ! -f "$PAIRINGS_FILE" ]]; then
    echo "Pairings file not found: $PAIRINGS_FILE" >&2
    exit 66
  fi
  PAIRINGS_JSON="$PAIRINGS_FILE"
else
  PAIRINGS_JSON="$(mktemp "${TMPDIR:-/tmp}/codexport-issue74-pairings.XXXXXX")"
  TEMP_FILES+=("$PAIRINGS_JSON")
  curl -fsS "${RELAY_BASE_URL}/v0/hosts/${HOST_ID}/pairings" >"$PAIRINGS_JSON"
fi

FILTERED_JSON="$(mktemp "${TMPDIR:-/tmp}/codexport-issue74-real-pairings.XXXXXX")"
TEMP_FILES+=("$FILTERED_JSON")

jq '
  [
    .devices[]
    | . as $device
    | select($device.revokedAtUnixTime == null)
    | select(([
        "CCCCCCCC-DDDD-EEEE-FFFF-000000000001",
        "DDDDDDDD-EEEE-FFFF-0000-000000000002",
        "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF"
      ] | index($device.deviceID)) | not)
    | {
        deviceDisplayName,
        deviceID,
        pairingRecordID,
        activeConnectionCount,
        pairedAtUnixTime
      }
  ]
  | sort_by(.deviceDisplayName // "", .deviceID, .pairingRecordID)
' "$PAIRINGS_JSON" >"$FILTERED_JSON"

REAL_ACTIVE_COUNT="$(jq 'length' "$FILTERED_JSON")"

if [[ "$LIST_ONLY" == "1" ]]; then
  jq --arg host_id "$HOST_ID" '{
      hostID: $host_id,
      realActiveDevices: .
    }' "$FILTERED_JSON"
  exit 0
fi

if [[ "$REAL_ACTIVE_COUNT" -lt 2 ]]; then
  echo "Relay has fewer than two non-synthetic active Pairing Records; pair both real iPhones first." >&2
  echo "Use: zsh scripts/issue74-export-real-pairing-env.sh --list" >&2
  exit 1
fi

if [[ "$AUTO_TWO" == "1" ]]; then
  if [[ -n "$IPHONE_A_SELECTOR" || -n "$IPHONE_B_SELECTOR" ]]; then
    echo "--auto-two cannot be combined with --iphone-a/--iphone-b selectors." >&2
    exit 64
  fi
  if [[ "$REAL_ACTIVE_COUNT" -ne 2 ]]; then
    echo "--auto-two requires exactly two non-synthetic active Pairing Records; found $REAL_ACTIVE_COUNT." >&2
    echo "Use --iphone-a and --iphone-b selectors to choose the intended phones." >&2
    exit 64
  fi
  IPHONE_A_RECORD="$(jq -c '.[0]' "$FILTERED_JSON")"
  IPHONE_B_RECORD="$(jq -c '.[1]' "$FILTERED_JSON")"
else
  if [[ -z "$IPHONE_A_SELECTOR" || -z "$IPHONE_B_SELECTOR" ]]; then
    echo "Missing --iphone-a/--iphone-b selectors. Use --auto-two only when exactly two real Pairing Records exist." >&2
    exit 64
  fi

  resolve_selector() {
    local role="$1"
    local selector="$2"
    local matches_json
    local match_count
    matches_json="$(jq -c --arg selector "$selector" '
      map(select(
        (.deviceID == $selector)
        or (.pairingRecordID == $selector)
        or (((.deviceDisplayName // "") | ascii_downcase) | contains($selector | ascii_downcase))
      ))
    ' "$FILTERED_JSON")"
    match_count="$(jq 'length' <<<"$matches_json")"
    case "$match_count" in
      0)
        echo "$role selector did not match any active non-synthetic Pairing Record: $selector" >&2
        exit 1
        ;;
      1)
        jq -c '.[0]' <<<"$matches_json"
        ;;
      *)
        echo "$role selector matched multiple active non-synthetic Pairing Records: $selector" >&2
        jq -r '.[] | "- " + ((.deviceDisplayName // "unknown") | tostring) + " / " + .deviceID + " / " + .pairingRecordID' <<<"$matches_json" >&2
        exit 1
        ;;
    esac
  }

  IPHONE_A_RECORD="$(resolve_selector "iPhoneA" "$IPHONE_A_SELECTOR")"
  IPHONE_B_RECORD="$(resolve_selector "iPhoneB" "$IPHONE_B_SELECTOR")"
fi

json_field() {
  local json="$1"
  local field="$2"
  jq -r --arg field "$field" '.[$field] // ""' <<<"$json"
}

shell_quote() {
  jq -nr --arg value "$1" '$value | @sh'
}

safe_comment() {
  printf '%s' "$1" | tr '\r\n' '  '
}

IPHONE_A_DEVICE_ID="$(json_field "$IPHONE_A_RECORD" deviceID)"
IPHONE_A_PAIRING_RECORD_ID="$(json_field "$IPHONE_A_RECORD" pairingRecordID)"
IPHONE_A_DISPLAY_NAME="$(json_field "$IPHONE_A_RECORD" deviceDisplayName)"
IPHONE_B_DEVICE_ID="$(json_field "$IPHONE_B_RECORD" deviceID)"
IPHONE_B_PAIRING_RECORD_ID="$(json_field "$IPHONE_B_RECORD" pairingRecordID)"
IPHONE_B_DISPLAY_NAME="$(json_field "$IPHONE_B_RECORD" deviceDisplayName)"

if [[ "$IPHONE_A_DEVICE_ID" == "$IPHONE_B_DEVICE_ID" || "$IPHONE_A_PAIRING_RECORD_ID" == "$IPHONE_B_PAIRING_RECORD_ID" ]]; then
  echo "iPhoneA and iPhoneB resolved to the same Pairing Record; choose two distinct real devices." >&2
  exit 1
fi

echo "# Real Relay Pairing Records for #74 TestFlight/manual verification."
echo "# iPhoneA sender: $(safe_comment "${IPHONE_A_DISPLAY_NAME:-unknown}")"
echo "export CODEXPORT_IOS_RELAY_DEVICE_ID=$(shell_quote "$IPHONE_A_DEVICE_ID")"
echo "export CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID=$(shell_quote "$IPHONE_A_PAIRING_RECORD_ID")"
echo "# iPhoneB observer: $(safe_comment "${IPHONE_B_DISPLAY_NAME:-unknown}")"
echo "export CODEXPORT_IOS_RELAY_DEVICE_ID_B=$(shell_quote "$IPHONE_B_DEVICE_ID")"
echo "export CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID_B=$(shell_quote "$IPHONE_B_PAIRING_RECORD_ID")"
echo "# Ensure CODEXPORT_ALLOW_SYNTHETIC_PAIRING_IDS is not set for close evidence."
