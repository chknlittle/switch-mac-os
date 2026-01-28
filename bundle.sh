#!/bin/bash
set -euo pipefail

APP_NAME="SwitchMacOS"
BUNDLE_ID="com.switch.macos"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR=".build/${APP_NAME}.app"
CONTENTS="${BUNDLE_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"

# Build
swift build

# Create .app bundle structure
rm -rf "${BUNDLE_DIR}"
mkdir -p "${MACOS}"

# Copy real binary
cp .build/debug/"${APP_NAME}" "${MACOS}/${APP_NAME}-bin"

# Write launcher script that sets the working directory to the repo root
cat > "${MACOS}/${APP_NAME}" <<LAUNCHER
#!/bin/bash
cd "${REPO_ROOT}"
exec "\$(dirname "\$0")/${APP_NAME}-bin" "\$@"
LAUNCHER
chmod +x "${MACOS}/${APP_NAME}"

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

echo "Built ${BUNDLE_DIR}"
