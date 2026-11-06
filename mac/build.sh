#!/bin/bash
# Construit "Claude Usage.app". Necessite seulement : xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

APP="Claude Usage.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Icone generee par icon/make-icons.swift a partir de la mascotte.
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# UNIVERSAL=1 : un seul binaire pour les Mac Apple Silicon et Intel (utilisé pour le dmg publié).
if [ "${UNIVERSAL:-0}" = "1" ]; then
  WORK="$(mktemp -d)"
  swiftc -O main.swift -target arm64-apple-macos13 -o "$WORK/arm64"
  swiftc -O main.swift -target x86_64-apple-macos13 -o "$WORK/x86_64"
  lipo -create "$WORK/arm64" "$WORK/x86_64" -output "$APP/Contents/MacOS/ClaudeUsage"
  rm -rf "$WORK"
else
  swiftc -O main.swift -o "$APP/Contents/MacOS/ClaudeUsage"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Usage</string>
  <key>CFBundleIdentifier</key><string>local.claudeusage.widget</string>
  <key>CFBundleExecutable</key><string>ClaudeUsage</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Signature locale : suffisante pour ton propre Mac.
codesign --force --sign - "$APP"

echo "OK : $APP"
