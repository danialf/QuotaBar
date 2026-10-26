#!/usr/bin/env bash
# Builds a release QuotaBar.app into ./build. Regenerate the icon with:
#   swift run QuotaBar --make-icon /tmp/AppIcon.iconset && iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
# Pass --install to copy it to ~/Applications
# (launch-at-login needs the app to live somewhere stable).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/QuotaBar"
APP="build/QuotaBar.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/QuotaBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    pkill -x QuotaBar 2>/dev/null || true
    rm -rf "$HOME/Applications/QuotaBar.app"
    cp -R "$APP" "$HOME/Applications/"
    open "$HOME/Applications/QuotaBar.app"
    echo "Installed to ~/Applications/QuotaBar.app"
fi
