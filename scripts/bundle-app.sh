#!/bin/sh
# Wrap the NarrateApp executable in a minimal Narrate.app (unsigned) so it launches like a normal Mac app.
# Usage: scripts/bundle-app.sh [debug|release]   -> .build/Narrate.app
set -eu
config="${1:-release}"
cd "$(dirname "$0")/.."
swift build -c "$config" --product NarrateApp
bin="$(swift build -c "$config" --show-bin-path)"
app=.build/Narrate.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/NarrateApp" "$app/Contents/MacOS/Narrate"
# Dynamic library products (MisakiSwift) load from @rpath, which includes the executable's folder.
find "$bin" -maxdepth 1 -name '*.dylib' -exec cp {} "$app/Contents/MacOS/" \;
# SwiftPM's generated Bundle.module looks for dependency resource bundles (KokoroTTS, MisakiSwift…) at
# Bundle.main.bundleURL, which for an app is the .app folder itself. Fine unsigned; signing is M5.
find "$bin" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$app/" \;
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Narrate</string>
  <key>CFBundleDisplayName</key><string>Narrate</string>
  <key>CFBundleIdentifier</key><string>com.github.djui.narrate</string>
  <key>CFBundleExecutable</key><string>Narrate</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.4</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
echo "$app"
