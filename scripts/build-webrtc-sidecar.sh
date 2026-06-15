#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${ROOT_DIR}/.build/DerivedData-WebRTCSidecar}"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT_DIR}/.scratch/webrtc-sidecar}"
BUILD_PRODUCTS_DIR="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}-maccatalyst"
EXECUTABLE_NAME="codexport-webrtc-sidecar"

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
mkdir -p "${OUTPUT_DIR}/PackageFrameworks"
cp "${SOURCE_EXECUTABLE}" "${OUTPUT_DIR}/${EXECUTABLE_NAME}"
rsync -a --delete "${SOURCE_WEBRTC_FRAMEWORK}" "${OUTPUT_DIR}/PackageFrameworks/"
chmod +x "${OUTPUT_DIR}/${EXECUTABLE_NAME}"

# Xcode embeds an absolute PackageFrameworks rpath into the executable. Replace
# it with a relative rpath so HostAgent can launch the helper from .scratch,
# /Applications, or any future signed app bundle layout.
for rpath in $(otool -l "${OUTPUT_DIR}/${EXECUTABLE_NAME}" | awk '/cmd LC_RPATH/{capture=1; next} capture && /path /{print $2; capture=0}'); do
  if [[ "${rpath}" == *"/PackageFrameworks" ]]; then
    install_name_tool -delete_rpath "${rpath}" "${OUTPUT_DIR}/${EXECUTABLE_NAME}" || true
  fi
done
install_name_tool -add_rpath "@executable_path/PackageFrameworks" "${OUTPUT_DIR}/${EXECUTABLE_NAME}"

codesign --force --deep --sign - "${OUTPUT_DIR}/PackageFrameworks/WebRTC.framework/Versions/A" >/dev/null
codesign --force --sign - "${OUTPUT_DIR}/${EXECUTABLE_NAME}" >/dev/null
codesign --verify --deep --strict "${OUTPUT_DIR}/${EXECUTABLE_NAME}"

echo "${OUTPUT_DIR}/${EXECUTABLE_NAME}"
