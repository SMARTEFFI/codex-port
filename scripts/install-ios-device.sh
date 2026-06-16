#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

DEVICE_SELECTOR="${CODEXPORT_IOS_DEVICE_SELECTOR:-min}"
PROJECT_PATH="${CODEXPORT_XCODE_PROJECT:-CodexPort.xcodeproj}"
SCHEME="${CODEXPORT_XCODE_SCHEME:-CodexPort}"
CONFIGURATION="${CODEXPORT_XCODE_CONFIGURATION:-Debug}"
BUNDLE_ID="${CODEXPORT_IOS_BUNDLE_ID:-com.smarteffi.codexport}"
DERIVED_DATA_PATH="${CODEXPORT_DERIVED_DATA_PATH:-$ROOT_DIR/.scratch/DerivedData/DeviceInstall}"
KEYCHAIN_PATH="${CODEXPORT_KEYCHAIN_PATH:-$HOME/Library/Keychains/login.keychain-db}"
LAUNCH_AFTER_INSTALL=1

usage() {
  cat >&2 <<'USAGE'
Usage:
  zsh scripts/install-ios-device.sh [device-name-or-udid-or-coredevice-id] [--no-launch]

Builds CodexPort for a connected physical iOS device, installs it with
devicectl, and launches it by default.

Defaults:
  device selector: min
  scheme: CodexPort
  configuration: Debug
  bundle id: com.smarteffi.codexport

Environment overrides:
  CODEXPORT_IOS_DEVICE_SELECTOR
  CODEXPORT_XCODE_PROJECT
  CODEXPORT_XCODE_SCHEME
  CODEXPORT_XCODE_CONFIGURATION
  CODEXPORT_XCODE_DEVELOPMENT_TEAM
  CODEXPORT_DERIVED_DATA_PATH
  CODEXPORT_KEYCHAIN_PATH
  CODEXPORT_SKIP_KEYCHAIN_UNLOCK=1
  CODEXPORT_XCODE_ALLOW_PROVISIONING_UPDATES=0
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --no-launch)
      LAUNCH_AFTER_INSTALL=0
      shift
      ;;
    --device)
      if [[ $# -lt 2 ]]; then
        echo "--device requires a value." >&2
        exit 64
      fi
      DEVICE_SELECTOR="$2"
      shift 2
      ;;
    --*)
      echo "Unknown option: $1" >&2
      usage
      exit 64
      ;;
    *)
      DEVICE_SELECTOR="$1"
      shift
      ;;
  esac
done

if ! command -v jq >/dev/null; then
  echo "Missing jq; required to parse devicectl device metadata." >&2
  exit 69
fi

device_json="$(mktemp /tmp/codexport-devices-json.XXXXXX)"
cleanup() {
  rm -f "$device_json"
  noglob rm -f /tmp/codexport-codesign-probe-* 2>/dev/null || true
}
trap cleanup EXIT

xcrun devicectl list devices --json-output "$device_json" >/dev/null

matches=("${(@f)$(jq -r --arg selector "$DEVICE_SELECTOR" '
  .result.devices[]
  | select((.connectionProperties.tunnelState // "") == "connected")
  | select(
      (.identifier // "") == $selector
      or (.hardwareProperties.udid // "") == $selector
      or (.deviceProperties.name // "") == $selector
    )
  | [
      .identifier,
      .hardwareProperties.udid,
      .deviceProperties.name,
      .hardwareProperties.marketingName,
      .deviceProperties.osVersionNumber
    ]
  | @tsv
' "$device_json")}")

if [[ ${#matches[@]} -eq 0 || -z "${matches[1]:-}" ]]; then
  echo "No connected physical iOS device matched selector: $DEVICE_SELECTOR" >&2
  echo >&2
  echo "Connected devices:" >&2
  jq -r '
    .result.devices[]
    | select((.connectionProperties.tunnelState // "") == "connected")
    | "  name=\(.deviceProperties.name // "?") coreDeviceId=\(.identifier // "?") udid=\(.hardwareProperties.udid // "?") model=\(.hardwareProperties.marketingName // "?") os=\(.deviceProperties.osVersionNumber // "?")"
  ' "$device_json" >&2
  exit 69
fi

if [[ ${#matches[@]} -gt 1 ]]; then
  echo "Multiple connected devices matched selector: $DEVICE_SELECTOR" >&2
  printf '  %s\n' "${matches[@]}" >&2
  echo "Pass --device <udid-or-coredevice-id> to disambiguate." >&2
  exit 64
fi

IFS=$'\t' read -r CORE_DEVICE_ID XCODE_DEVICE_ID DEVICE_NAME MARKETING_NAME OS_VERSION <<<"${matches[1]}"

if [[ -z "$CORE_DEVICE_ID" || -z "$XCODE_DEVICE_ID" ]]; then
  echo "Matched device is missing CoreDevice id or hardware UDID." >&2
  echo "${matches[1]}" >&2
  exit 69
fi

unlock_keychain() {
  if [[ "${CODEXPORT_SKIP_KEYCHAIN_UNLOCK:-0}" == "1" ]]; then
    return 0
  fi

  security unlock-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
}

probe_codesign_access() {
  local identities
  identities=("${(@f)$(security find-identity -v -p codesigning | grep 'Apple Development:' || true)}")
  if [[ ${#identities[@]} -eq 0 ]]; then
    echo "No Apple Development signing identity is available in the current keychains." >&2
    return 1
  fi

  local probe_file="/tmp/codexport-codesign-probe-$$"
  printf 'probe' >"$probe_file"

  local line hash name
  for line in "${identities[@]}"; do
    hash="$(awk '{print $2}' <<<"$line")"
    name="$(sed -E 's/^ *[0-9]+\) [A-F0-9]+ "(.*)"$/\1/' <<<"$line")"
    if codesign --force --sign "$hash" --timestamp=none "$probe_file" >/dev/null 2>&1; then
      echo "codesign identity accessible: $name"
      rm -f "$probe_file"
      return 0
    fi
  done

  rm -f "$probe_file"
  cat >&2 <<EOF
Apple Development identities exist, but CLI codesign cannot access their private keys.

Try once in Terminal:
  security unlock-keychain "$KEYCHAIN_PATH"

Then rerun:
  zsh scripts/install-ios-device.sh "$DEVICE_SELECTOR"

If it still fails, open Keychain Access and allow codesign/Xcode access for the
Apple Development private key used by Team BJ43NTPPMD.
EOF
  return 1
}

mkdir -p "$DERIVED_DATA_PATH" "$ROOT_DIR/.scratch/logs"

echo "Target device: $DEVICE_NAME ($MARKETING_NAME, iOS $OS_VERSION)"
echo "  xcodebuild destination id: $XCODE_DEVICE_ID"
echo "  devicectl device id:       $CORE_DEVICE_ID"

unlock_keychain
probe_codesign_access

app_path="$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}-iphoneos/CodexPort.app"
build_log="$ROOT_DIR/.scratch/logs/ios-device-build.log"

xcodebuild_args=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -sdk iphoneos
  -destination "id=${XCODE_DEVICE_ID}"
  -derivedDataPath "$DERIVED_DATA_PATH"
)

if [[ "${CODEXPORT_XCODE_ALLOW_PROVISIONING_UPDATES:-1}" != "0" ]]; then
  xcodebuild_args+=(-allowProvisioningUpdates)
fi

if [[ -n "${CODEXPORT_XCODE_DEVELOPMENT_TEAM:-}" ]]; then
  xcodebuild_args+=("DEVELOPMENT_TEAM=${CODEXPORT_XCODE_DEVELOPMENT_TEAM}" "CODE_SIGN_STYLE=Automatic")
fi

echo "Building iOS app..."
if ! xcodebuild "${xcodebuild_args[@]}" build >"$build_log" 2>&1; then
  echo "xcodebuild failed. Log: $build_log" >&2
  tail -n 80 "$build_log" >&2 || true
  exit 65
fi

echo "Installing app..."
xcrun devicectl device install app --device "$CORE_DEVICE_ID" "$app_path"

if [[ "$LAUNCH_AFTER_INSTALL" == "1" ]]; then
  echo "Launching app..."
  xcrun devicectl device process launch \
    --device "$CORE_DEVICE_ID" \
    --terminate-existing \
    "$BUNDLE_ID"
fi

echo
echo "Installed CodexPort on $DEVICE_NAME."
echo "App path: $app_path"
echo "Build log: $build_log"
