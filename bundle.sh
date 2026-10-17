#!/bin/bash
set -euo pipefail

APP_NAME="SwitchMacOS"
BUNDLE_ID="com.switch.macos"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR=".build/${APP_NAME}.app"
CONTENTS="${BUNDLE_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"
ENTITLEMENTS="${REPO_ROOT}/SwitchMacOS.entitlements"

INSTALL_TO_APPLICATIONS=1
for arg in "$@"; do
  if [ "$arg" = "--no-install" ]; then
    INSTALL_TO_APPLICATIONS=0
  fi
done

# Build
swift build

# Create .app bundle structure
rm -rf "${BUNDLE_DIR}"
mkdir -p "${MACOS}"

# Optional bundle resources
mkdir -p "${RESOURCES}"

# Copy real binary as the bundle executable.
# Keep the CFBundleExecutable as a Mach-O binary (not a shell script) so macOS
# treats the process as a real app for things like notifications.
cp ".build/debug/${APP_NAME}" "${MACOS}/${APP_NAME}"

# Copy SPM resource bundles (e.g. Highlightr's highlight.min.js + theme CSS)
# into the app so Bundle.module can find them at runtime. Without this,
# Highlightr() fails to locate its resources and highlighting silently no-ops.
for res_bundle in ".build/debug/"*.bundle; do
  if [ -d "$res_bundle" ]; then
    cp -R "$res_bundle" "${RESOURCES}/"
  fi
done

# If a repo-root .env exists, bundle it for convenient local dev.
if [ -f "${REPO_ROOT}/.env" ]; then
  cp "${REPO_ROOT}/.env" "${RESOURCES}/.env"
fi

# Write Info.plist
cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc code sign the app bundle with entitlements.
# This is required for notifications to work on macOS.
codesign --force --deep --sign - --entitlements "${ENTITLEMENTS}" "${BUNDLE_DIR}"

if [ "$INSTALL_TO_APPLICATIONS" -eq 1 ]; then
  INSTALLED="/Applications/${APP_NAME}.app"
  # A real (copied) app there would shadow the symlink: ln would put the
  # link inside it, and Spotlight/Launchpad would keep opening the old build.
  if [ -e "${INSTALLED}" ] && [ ! -L "${INSTALLED}" ]; then
    rm -rf "${INSTALLED}"
  fi
  ln -sfh "${REPO_ROOT}/${BUNDLE_DIR}" "${INSTALLED}"
  echo "Built and signed ${BUNDLE_DIR} (symlinked to ${INSTALLED})"
else
  echo "Built and signed ${BUNDLE_DIR}"
fi
