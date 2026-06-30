#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

NAME="QuotaPulse"
APP_DIR="./outputs/${NAME}.app"
SWIFT="QuotaPulse.swift"

echo ">> Compiling ${SWIFT} ..."
swiftc -O -o "${NAME}" -sdk "$(xcrun --show-sdk-path)" "${SWIFT}"

echo ">> Packaging ${NAME}.app ..."
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
cp "${NAME}" "${APP_DIR}/Contents/MacOS/${NAME}"

cat > "${APP_DIR}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>QuotaPulse</string>
    <key>CFBundleDisplayName</key>
    <string>QuotaPulse</string>
    <key>CFBundleIdentifier</key>
    <string>com.drok.quota-pulse</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>QuotaPulse</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo ">> Done. App at: ${APP_DIR}"
echo "   Run: open \"${APP_DIR}\""
