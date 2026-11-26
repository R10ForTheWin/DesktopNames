#!/bin/bash
# Builds DesktopNames.app and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

BUILD="$(mktemp -d)"
APP="$BUILD/DesktopNames.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/"

swiftc -O -swift-version 5 DesktopNames.swift -o "$APP/Contents/MacOS/DesktopNames" \
  -framework Cocoa -framework ApplicationServices -framework ServiceManagement

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DesktopNames</string>
  <key>CFBundleDisplayName</key><string>DesktopNames</string>
  <key>CFBundleIdentifier</key><string>local.desktopnames</string>
  <key>CFBundleExecutable</key><string>DesktopNames</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST

xattr -cr "$APP"
# Sign with the local "DesktopNames Local Signing" identity if present (keeps the
# Accessibility permission across rebuilds); fall back to ad-hoc signing.
ID=$(security find-identity -p codesigning 2>/dev/null | awk '/DesktopNames Local Signing/ {print $2; exit}')
if [ -n "$ID" ]; then
  # Retry once: the keychain sometimes refuses the first request (errSecInternalComponent).
  if ! codesign --force --sign "$ID" "$APP" && ! codesign --force --sign "$ID" "$APP"; then
    echo "ERROR: couldn't sign with 'DesktopNames Local Signing'. Not installing, because an"
    echo "ad-hoc build would lose the Accessibility permission. Unlock the keychain and rerun."
    exit 1
  fi
  echo "Signed with local identity"
else
  codesign --force --sign - "$APP"
fi

mkdir -p "$HOME/Applications"
pkill -x DesktopNames 2>/dev/null || true
rm -rf "$HOME/Applications/DesktopNames.app"
cp -R "$APP" "$HOME/Applications/"
echo "Installed to ~/Applications/DesktopNames.app"
