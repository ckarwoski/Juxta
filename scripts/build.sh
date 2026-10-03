#!/bin/bash
# Builds build/Juxta.app (release). Pass --install to copy it to ~/Applications and
# link the `juxta` command into ~/.local/bin.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

if [ ! -f build/AppIcon.icns ]; then
    mkdir -p build/AppIcon.iconset
    swift scripts/make-icon.swift build/icon-1024.png
    for s in 16 32 128 256 512; do
        sips -z $s $s build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
        sips -z $((s*2)) $((s*2)) build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
    done
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

APP=build/Juxta.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Juxta" "$APP/Contents/MacOS/Juxta"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    mkdir -p ~/Applications ~/.local/bin
    rm -rf ~/Applications/Juxta.app
    cp -R "$APP" ~/Applications/
    ln -sf "$PWD/scripts/juxta" ~/.local/bin/juxta
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/Juxta.app
    echo "Installed ~/Applications/Juxta.app and ~/.local/bin/juxta"
fi
