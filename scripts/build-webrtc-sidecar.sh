#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/scripts/lib/codesign-identity.sh"

CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${ROOT_DIR}/.build/DerivedData-WebRTCSidecar}"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT_DIR}/.scratch/webrtc-sidecar}"
BUILD_PRODUCTS_DIR="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}-maccatalyst"
EXECUTABLE_NAME="codexport-webrtc-sidecar"
APP_NAME="CodexPort WebRTC Sidecar"
APP_DIR="${OUTPUT_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"
BUNDLE_IDENTIFIER="${CODEXPORT_WEBRTC_SIDECAR_BUNDLE_IDENTIFIER:-com.smarteffi.codexport.webrtc-sidecar}"

codesign_bundle() {
  local identity
  identity="$(resolve_codexport_codesign_identity)"
  if [[ -n "${identity}" ]]; then
    echo "Signing ${APP_NAME}.app with identity: ${identity}" >&2
    codesign --force --timestamp=none --sign "${identity}" "${FRAMEWORKS_DIR}/WebRTC.framework/Versions/A"
    codesign --force --timestamp=none --sign "${identity}" "${MACOS_DIR}/${EXECUTABLE_NAME}"
    codesign --force --deep --timestamp=none --sign "${identity}" "${APP_DIR}"
  else
    echo "warning: no Apple codesigning identity found; falling back to ad-hoc signing." >&2
    codesign --force --deep --sign - "${FRAMEWORKS_DIR}/WebRTC.framework/Versions/A"
    codesign --force --sign - "${MACOS_DIR}/${EXECUTABLE_NAME}"
    codesign --force --deep --sign - "${APP_DIR}"
  fi
}

cd "${ROOT_DIR}"

xcodebuild \
  -project CodexPort.xcodeproj \
  -scheme "${EXECUTABLE_NAME}" \
  -configuration "${CONFIGURATION}" \
  -destination "platform=macOS,variant=Mac Catalyst" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  build

SOURCE_EXECUTABLE="${BUILD_PRODUCTS_DIR}/${EXECUTABLE_NAME}"
SOURCE_WEBRTC_FRAMEWORK="${BUILD_PRODUCTS_DIR}/WebRTC.framework"

if [[ ! -x "${SOURCE_EXECUTABLE}" ]]; then
  echo "Missing built sidecar executable: ${SOURCE_EXECUTABLE}" >&2
  exit 1
fi

if [[ ! -d "${SOURCE_WEBRTC_FRAMEWORK}" ]]; then
  echo "Missing built WebRTC.framework: ${SOURCE_WEBRTC_FRAMEWORK}" >&2
  exit 1
fi

rm -rf "${OUTPUT_DIR}"
mkdir -p "${MACOS_DIR}" "${FRAMEWORKS_DIR}"
cp "${SOURCE_EXECUTABLE}" "${MACOS_DIR}/${EXECUTABLE_NAME}"
rsync -a --delete "${SOURCE_WEBRTC_FRAMEWORK}" "${FRAMEWORKS_DIR}/"
chmod +x "${MACOS_DIR}/${EXECUTABLE_NAME}"

cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleExecutable</key>
	<string>${EXECUTABLE_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_IDENTIFIER}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
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

# Xcode embeds an absolute PackageFrameworks rpath into the executable. Replace
# it with a relative rpath so HostAgent can launch the helper from the signed app
# bundle, .scratch, /Applications, or any future installation layout.
for rpath in $(otool -l "${MACOS_DIR}/${EXECUTABLE_NAME}" | awk '/cmd LC_RPATH/{capture=1; next} capture && /path /{print $2; capture=0}'); do
  if [[ "${rpath}" == *"/PackageFrameworks" ]]; then
    install_name_tool -delete_rpath "${rpath}" "${MACOS_DIR}/${EXECUTABLE_NAME}" || true
  fi
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "${MACOS_DIR}/${EXECUTABLE_NAME}"

codesign_bundle
codesign --verify --deep --strict "${APP_DIR}"

echo "${MACOS_DIR}/${EXECUTABLE_NAME}"
