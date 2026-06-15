#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  cat >&2 <<'USAGE'
Usage:
  zsh scripts/issue74-manual-testflight-smoke.sh <idle-thread-id> [marker]

Starts the current HostAgent P2P listener, prints TestFlight/manual verification
deeplinks for iPhoneB observer and iPhoneA sender, then waits for the same
metadata-only #74 HostAgent log verifier used by simulator/device smoke.

Open the target idle thread in Codex TUI before running this script. Then open
the printed iPhoneB observer URL first, wait for it to attach, and open the
iPhoneA sender URL second.

Required for real-device/TestFlight evidence:
  CODEXPORT_IOS_RELAY_DEVICE_ID
  CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID
  CODEXPORT_IOS_RELAY_DEVICE_ID_B
  CODEXPORT_IOS_RELAY_PAIRING_RECORD_ID_B

Use values from:
  zsh scripts/issue74-list-pairing-records.sh

Set CODEXPORT_SKIP_ISSUE74_VERIFY=1 only when printing URLs without waiting.
Set CODEXPORT_ALLOW_SYNTHETIC_PAIRING_IDS=1 only for simulator/dev rehearsal;
synthetic identities are not #74 close evidence.
USAGE
  exit 64
fi

THREAD_ID="$1"
MARKER="${2:-ISSUE74-PHYSICAL-IDLE-TUI-$(date +%Y%m%d%H%M%S)}"
HOSTAGENT_RUN_ID="${CODEXPORT_ISSUE74_RUN_ID:-issue74-manual-$(date +%Y%m%d%H%M%S)-$$}"
CODEX_CONTROL_SOCKET_PATH="${CODEXPORT_CODEX_CONTROL_SOCKET_PATH:-$HOME/.codex/app-server-control/app-server-control.sock}"
VERIFY_TIMEOUT_SECONDS="${CODEXPORT_ISSUE74_VERIFY_TIMEOUT_SECONDS:-600}"
VERIFY_INTERVAL_SECONDS="${CODEXPORT_ISSUE74_VERIFY_INTERVAL_SECONDS:-5}"

require_real_relay_identity() {
  local name="$1"
  local value="${(P)name:-}"
  if [[ -z "$value" ]]; then
    echo "Missing required environment variable for TestFlight/manual #74 evidence: $name" >&2
    echo "Pair both real iPhones first, then export their Relay device IDs and Pairing Record IDs." >&2
    echo "Use zsh scripts/issue74-list-pairing-records.sh to list active Pairing Record metadata." >&2
    echo "Set CODEXPORT_ALLOW_SYNTHETIC_PAIRING_IDS=1 only for local/dev rehearsal, not close evidence." >&2
    exit 64
  fi
  printf '%s' "$value"
}

if [[ "${CODEXPORT_ALLOW_SYNTHETIC_PAIRING_IDS:-0}" == "1" ]]; then
  HOST_ID="${CODEXPORT_RELAY_HOST_ID:-11111111-2222-3333-4444-555555555555}"
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

DEEPLINK_OUTPUT="$(zsh scripts/issue74-make-verify-deeplinks.sh "$THREAD_ID" "$MARKER")"

echo
echo "Prepared #74 manual/TestFlight deeplinks."
echo "Thread: $THREAD_ID"
echo "Marker: $MARKER"
echo "iPhoneA relay device identity: $IPHONE_A_RELAY_DEVICE_ID"
echo "iPhoneB relay device identity: $IPHONE_B_RELAY_DEVICE_ID"
echo
echo "$DEEPLINK_OUTPUT"
echo
echo "Do not open these URLs until HostAgent reports ready below."

eval "$(zsh scripts/issue74-start-hostagent-p2p.sh "$HOSTAGENT_RUN_ID")"
HOSTAGENT_STDOUT="$CODEXPORT_HOSTAGENT_STDOUT"

echo
echo "HostAgent P2P listener is ready for #74 manual/TestFlight verification."
echo "Thread: $THREAD_ID"
echo "Marker: $MARKER"
echo "HostAgent run id: $HOSTAGENT_RUN_ID"
echo "HostAgent stdout: $HOSTAGENT_STDOUT"
echo "iPhoneA relay device identity: $IPHONE_A_RELAY_DEVICE_ID"
echo "iPhoneB relay device identity: $IPHONE_B_RELAY_DEVICE_ID"
echo
echo "Open order:"
echo "1. Open the iPhoneB observer deeplink first."
echo "2. Wait for iPhoneB to attach to the target thread."
echo "3. Open the iPhoneA sender deeplink second."
echo "4. Confirm the already-open Codex TUI updates live without leaving/reopening the thread."

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
    echo
    echo "Metadata gate passed. Record the human observation of the open Codex TUI before closing #74."
    exit 0
  fi
  sleep "$VERIFY_INTERVAL_SECONDS"
done

echo "$last_output"
echo
echo "Issue #74 manual/TestFlight smoke timed out after ${VERIFY_TIMEOUT_SECONDS}s." >&2
exit 1
