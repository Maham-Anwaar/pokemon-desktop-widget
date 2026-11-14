#!/bin/zsh
# Builds "Pokemon Roam.app" and installs it to /Applications.
# Uses the same sprites as the widget (~/Documents/Pokemon Widget/sprites): run ../fetch_sprites.sh first.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Pokemon Roam.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun swiftc -O -sdk "$(xcrun --show-sdk-path --sdk macosx)" -target "$(uname -m)-apple-macos14.0" \
  -framework WebKit -framework ServiceManagement \
  main.swift ../sprites.swift -o "$APP/Contents/MacOS/PokemonRoam"

cp roam.html "$APP/Contents/Resources/"
cp AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>PokemonRoam</string>
  <key>CFBundleIdentifier</key><string>local.pokemonroam</string>
  <key>CFBundleName</key><string>Pokemon Roam</string>
  <key>CFBundleDisplayName</key><string>Pokémon Roam</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Pokémon Roam reads its sprites from Documents › Pokemon Widget.</string>
</dict></plist>
EOF

ID=$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}')
codesign --force --timestamp=none --sign "${ID:--}" "$APP"
codesign --verify --strict "$APP"

pkill -x PokemonRoam 2>/dev/null || true
rm -rf /Applications/"Pokemon Roam.app"
cp -R "$APP" /Applications/
echo "Installed /Applications/Pokemon Roam.app"
