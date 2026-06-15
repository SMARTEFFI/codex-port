#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/scripts/lib/codesign-identity.sh"

APP_NAME="CodexPort Host Agent"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-debug}"
APP_DIR="${ROOT_DIR}/.scratch/apps/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
EXECUTABLE_NAME="codexport-host-agent-menu"
BUNDLE_IDENTIFIER="${CODEXPORT_HOST_AGENT_BUNDLE_IDENTIFIER:-com.smarteffi.codexport.hostagent}"

codesign_app() {
  local identity
  identity="$(resolve_codexport_codesign_identity)"
  if [[ -n "${identity}" ]]; then
    echo "Signing ${APP_NAME}.app with identity: ${identity}" >&2
    codesign --force --deep --timestamp=none --sign "${identity}" "${APP_DIR}"
  else
    echo "warning: no Apple codesigning identity found; falling back to ad-hoc signing." >&2
    codesign --force --deep --sign - "${APP_DIR}"
  fi
}

cd "${ROOT_DIR}"
swift build --configuration "${BUILD_CONFIGURATION}" --product "${EXECUTABLE_NAME}"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp "${ROOT_DIR}/.build/${BUILD_CONFIGURATION}/${EXECUTABLE_NAME}" "${MACOS_DIR}/${EXECUTABLE_NAME}"
chmod +x "${MACOS_DIR}/${EXECUTABLE_NAME}"

cat > "${CONTENTS_DIR}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>CodexPort Host Agent</string>
	<key>CFBundleExecutable</key>
	<string>codexport-host-agent-menu</string>
	<key>CFBundleIdentifier</key>
	<string>__BUNDLE_IDENTIFIER__</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>CodexPort Host Agent</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.2</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSLocalNetworkUsageDescription</key>
	<string>CodexPort uses local network access to establish peer-to-peer WebRTC connections between this Mac and paired iOS devices.</string>
</dict>
</plist>
PLIST
perl -0pi -e "s/__BUNDLE_IDENTIFIER__/${BUNDLE_IDENTIFIER}/g" "${CONTENTS_DIR}/Info.plist"

codesign_app
codesign --verify --deep --strict "${APP_DIR}"

echo "${APP_DIR}"
