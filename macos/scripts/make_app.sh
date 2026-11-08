#!/bin/bash
# 打包 LanDrop.app（macOS）
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/LanDrop"
APP="build/LanDrop.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LanDrop"
cp assets/LanDrop.icns "$APP/Contents/Resources/LanDrop.icns"
if [ -d ".build/$CONFIG/LanDrop_LanDrop.bundle" ]; then
  cp -R ".build/$CONFIG/LanDrop_LanDrop.bundle" "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>LanDrop</string>
    <key>CFBundleDisplayName</key>
    <string>LanDrop</string>
    <key>CFBundleIdentifier</key>
    <string>com.landrop.mac</string>
    <key>CFBundleExecutable</key>
    <string>LanDrop</string>
    <key>CFBundleIconFile</key>
    <string>LanDrop</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>LanDrop 需要在局域网内发现设备并传输文件。</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_landrop._tcp</string>
    </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "==> 已生成 $APP"
echo "    双击运行，或：open $APP"
