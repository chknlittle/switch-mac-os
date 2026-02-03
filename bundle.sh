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
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSExceptionDomains</key>
        <dict>
            <key>100.119.143.40</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
                <key>NSIncludesSubdomains</key>
                <true/>
            </dict>
            <key>claude.local</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
                <key>NSIncludesSubdomains</key>
                <true/>
            </dict>
        </dict>
    </dict>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc code sign the app bundle with entitlements.
# This is required for notifications to work on macOS.
codesign --force --deep --sign - --entitlements "${ENTITLEMENTS}" "${BUNDLE_DIR}"

# Symlink to Applications for Spotlight
ln -sfh "${REPO_ROOT}/${BUNDLE_DIR}" "/Applications/${APP_NAME}.app"

echo "Built and signed ${BUNDLE_DIR} (symlinked to /Applications)"
