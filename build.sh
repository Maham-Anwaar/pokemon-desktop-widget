#!/bin/zsh
# Builds "Pokemon Widget.app" and installs it to ~/Applications.
# Usage: ./build.sh            (signs with your Apple Development certificate if present)
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Pokemon Widget.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun swiftc -O -sdk "$(xcrun --show-sdk-path --sdk macosx)" -target "$(uname -m)-apple-macos14.0" \
  -framework WebKit -framework IOKit -framework ServiceManagement \
  main.swift -o "$APP/Contents/MacOS/PokemonWidget"

cp widget.html AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>PokemonWidget</string>
  <key>CFBundleIdentifier</key><string>local.pokemonwidget</string>
  <key>CFBundleName</key><string>Pokemon Widget</string>
  <key>CFBundleDisplayName</key><string>Pokémon Widget</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Pokémon Widget reads its sprites and settings from Documents › Pokemon Widget.</string>
</dict></plist>
EOF

ID=$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}')
codesign --force --timestamp=none --sign "${ID:--}" "$APP"
codesign --verify --strict "$APP"

pkill -x PokemonWidget 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/"Pokemon Widget.app"
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/Pokemon Widget.app (signed with ${ID:-ad-hoc})"
