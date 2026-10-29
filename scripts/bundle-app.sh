#!/bin/sh
# Wrap the NarrateApp executable in Narrate.app so it launches like a normal Mac app (unsigned;
# scripts/release.sh signs and notarizes it).
# Usage: scripts/bundle-app.sh [debug|release]   -> .build/Narrate.app    (VERSION=0.5.0 to set the version)
set -eu
config="${1:-release}"
version="${VERSION:-0.5.0}"
cd "$(dirname "$0")/.."
swift build -c "$config" --product NarrateApp
bin="$(swift build -c "$config" --show-bin-path)"
app=.build/Narrate.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/NarrateApp" "$app/Contents/MacOS/Narrate"
# Dynamic library products (MisakiSwift) load from @rpath, which includes the executable's folder.
find "$bin" -maxdepth 1 -name '*.dylib' -exec cp {} "$app/Contents/MacOS/" \;
# SwiftPM's generated Bundle.module finds dependency resource bundles (KokoroTTS, MisakiSwift, MLX's
# metallib) in Bundle.main.resourceURL.
find "$bin" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$app/Contents/Resources/" \;
cp packaging/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Narrate</string>
  <key>CFBundleDisplayName</key><string>Narrate</string>
  <key>CFBundleIdentifier</key><string>com.github.djui.narrate</string>
  <key>CFBundleExecutable</key><string>Narrate</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>Apache-2.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key><array>
    <dict>
      <key>CFBundleTypeName</key><string>EPUB book</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>org.idpf.epub-container</string></array>
    </dict>
  </array>
</dict></plist>
PLIST
echo "$app"
