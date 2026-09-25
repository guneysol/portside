#!/bin/bash
# Builds Portside.app into ./build.
# Usage: ./build.sh [--open | --install]
#   --open     launch the freshly built app
#   --install  copy it to ~/Applications and launch it
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Portside.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Portside "$APP/Contents/MacOS/Portside"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" # regenerate: swift scripts/make-icon.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Portside</string>
    <key>CFBundleIdentifier</key><string>io.github.guneysol.portside</string>
    <key>CFBundleExecutable</key><string>Portside</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null # quiet "replacing existing signature"; failures still exit via set -e
echo "Built $APP"

relaunch() {
    pkill -x Portside 2>/dev/null && sleep 1 || true
    open "$1"
}

case "${1:-}" in
    --open) relaunch "$APP" ;;
    --install)
        mkdir -p ~/Applications
        rm -rf ~/Applications/Portside.app
        cp -R "$APP" ~/Applications/
        relaunch ~/Applications/Portside.app
        echo "Installed ~/Applications/Portside.app — look for it in your menu bar."
        ;;
esac
