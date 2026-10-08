#!/bin/bash
# Builds Portside.app into ./build.
# Usage: ./build.sh [--open | --install]
#   --open     launch the freshly built app
#   --install  copy it to /Applications (or ~/Applications if that isn't writable) and launch it
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
    <key>CFBundleShortVersionString</key><string>0.2.1</string>
    <key>CFBundleVersion</key><string>5</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null # quiet "replacing existing signature"; failures still exit via set -e
echo "Built $APP"

relaunch() {
    pkill -f 'Portside\.app/Contents/MacOS/Portside' 2>/dev/null && sleep 1 || true # this app only
    open "$1"
}

case "${1:-}" in
    --open) relaunch "$APP" ;;
    --install)
        # Where people look for apps. Admin accounts can write there without sudo;
        # everyone else gets the Applications folder in their home.
        if [[ -w /Applications ]]; then dest=/Applications; else dest=~/Applications; fi
        # Only ever replace or remove our own Portside.app, never another app with the same name.
        for dir in /Applications ~/Applications; do
            old="$dir/Portside.app"
            [[ -e "$old" ]] || continue
            id=$(defaults read "$old/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
            if [[ "$id" != io.github.guneysol.portside ]]; then
                [[ "$dir" == "$dest" ]] || continue
                echo "$old belongs to another app ($id). Move it, then run this again."
                exit 1
            fi
            rm -rf "$old" # also clears a copy left by an older install in the other folder
        done
        mkdir -p "$dest"
        cp -R "$APP" "$dest/"
        relaunch "$dest/Portside.app"
        echo "Installed $dest/Portside.app. It's running in your menu bar now."
        ;;
esac
