#!/usr/bin/env zsh
set -euo pipefail

HOST_ID="${CODEXPORT_RELAY_HOST_ID:-11111111-2222-3333-4444-555555555555}"
RELAY_BASE_URL="${CODEXPORT_RELAY_BASE_URL:-https://codexport.smarteffi.net}"

if ! command -v jq >/dev/null; then
  echo "Missing jq; required to format pairing-record metadata." >&2
  exit 69
fi

curl -fsS "${RELAY_BASE_URL}/v0/hosts/${HOST_ID}/pairings" \
  | jq '{
      hostID: "'"${HOST_ID}"'",
      activeDevices: [
        .devices[]
        | select(.revokedAtUnixTime == null)
        | {
            deviceDisplayName,
            deviceID,
            pairingRecordID,
            activeConnectionCount,
            pairedAtUnixTime
          }
      ]
    }'
