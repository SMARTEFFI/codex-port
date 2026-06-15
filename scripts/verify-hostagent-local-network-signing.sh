#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_AGENT_APP="${CODEXPORT_HOST_AGENT_MENU_APP_PATH:-$ROOT_DIR/.scratch/apps/CodexPort Host Agent.app}"
HOST_AGENT_EXECUTABLE="${CODEXPORT_HOST_AGENT_MENU_EXECUTABLE:-$HOST_AGENT_APP/Contents/MacOS/codexport-host-agent-menu}"
WEBRTC_SIDECAR_APP="${CODEXPORT_WEBRTC_SIDECAR_APP_PATH:-$ROOT_DIR/.scratch/webrtc-sidecar/CodexPort WebRTC Sidecar.app}"
WEBRTC_SIDECAR_EXECUTABLE="${CODEXPORT_WEBRTC_SIDECAR_PATH:-$WEBRTC_SIDECAR_APP/Contents/MacOS/codexport-webrtc-sidecar}"

require_path() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    echo "Missing path: $path" >&2
    exit 66
  fi
}

require_codesign_field() {
  local path="$1"
  local pattern="$2"
  local message="$3"
  if ! codesign -dv --verbose=4 "$path" 2>&1 | grep -E "$pattern" >/dev/null; then
    echo "$message" >&2
    codesign -dv --verbose=4 "$path" 2>&1 >&2 || true
    exit 65
  fi
}

require_app_bound_info_plist() {
  local path="$1"
  local message="$2"
  if ! codesign -dv --verbose=4 "$path" 2>&1 | grep -E '^Info\.plist entries=[1-9][0-9]*$|^Info\.plist=bound$' >/dev/null; then
    echo "$message" >&2
    codesign -dv --verbose=4 "$path" 2>&1 >&2 || true
    exit 65
  fi
}

require_plist_value() {
  local plist="$1"
  local key="$2"
  if ! /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1; then
    echo "Missing Info.plist key $key in $plist" >&2
    exit 65
  fi
}

require_path "$HOST_AGENT_APP"
require_path "$HOST_AGENT_EXECUTABLE"
require_path "$WEBRTC_SIDECAR_APP"
require_path "$WEBRTC_SIDECAR_EXECUTABLE"

codesign --verify --deep --strict "$HOST_AGENT_APP"
codesign --verify --deep --strict "$WEBRTC_SIDECAR_APP"

require_codesign_field "$HOST_AGENT_EXECUTABLE" '^Identifier=com\.smarteffi\.codexport\.hostagent$' \
  "HostAgent menu executable is not signed with the stable bundle identifier."
require_codesign_field "$WEBRTC_SIDECAR_EXECUTABLE" '^Identifier=com\.smarteffi\.codexport\.webrtc-sidecar$' \
  "WebRTC sidecar executable is not signed with the stable bundle identifier."
require_codesign_field "$HOST_AGENT_EXECUTABLE" '^TeamIdentifier=.+' \
  "HostAgent menu executable does not have a stable Apple TeamIdentifier."
require_codesign_field "$WEBRTC_SIDECAR_EXECUTABLE" '^TeamIdentifier=.+' \
  "WebRTC sidecar executable does not have a stable Apple TeamIdentifier."
require_app_bound_info_plist "$HOST_AGENT_EXECUTABLE" \
  "HostAgent menu executable does not bind Info.plist into the code signature."
require_app_bound_info_plist "$WEBRTC_SIDECAR_EXECUTABLE" \
  "WebRTC sidecar executable does not bind Info.plist into the code signature."

require_plist_value "$HOST_AGENT_APP/Contents/Info.plist" NSLocalNetworkUsageDescription
require_plist_value "$WEBRTC_SIDECAR_APP/Contents/Info.plist" NSLocalNetworkUsageDescription

echo "HostAgent local-network signing is stable."
