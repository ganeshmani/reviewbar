#!/bin/bash
# Builds ReviewBar.app (release, universal). Usage: scripts/build-app.sh [--install]
# SIGN_ID="Developer ID Application: …" signs with hardened runtime for distribution; default is ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/ReviewBar"
APP="build/ReviewBar.app"
VERSION="1.0.6"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ReviewBar"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.reviewbar.ReviewBar</string>
  <key>CFBundleName</key><string>ReviewBar</string>
  <key>CFBundleDisplayName</key><string>ReviewBar</string>
  <key>CFBundleExecutable</key><string>ReviewBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Personal tool. All data stays on this Mac.</string>
</dict>
</plist>
PLIST

if [[ -n "${SIGN_ID:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x ReviewBar 2>/dev/null || true
  rm -rf "$HOME/Applications/ReviewBar.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "Installed to ~/Applications/ReviewBar.app"
  open "$HOME/Applications/ReviewBar.app"
fi
