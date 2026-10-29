#!/bin/sh
# Build, sign, notarize and staple Narrate.app, then zip it for a GitHub release.
# Usage: NOTARY_PROFILE=<name> scripts/release.sh 0.5.0 [--publish]
#   NOTARY_PROFILE  a notarytool keychain profile (xcrun notarytool store-credentials <name> ...)
#   IDENTITY        signing identity (default: the first "Developer ID Application" in the keychain)
#   --publish       also create the GitHub release v<version> with the zip attached
set -eu
version="${1:?usage: scripts/release.sh VERSION [--publish]}"
publish="${2:-}"
profile="${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"
identity="${IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
[ -n "$identity" ] || { echo "no Developer ID Application identity found" >&2; exit 1; }
cd "$(dirname "$0")/.."

VERSION="$version" scripts/bundle-app.sh release
app=.build/Narrate.app
zip=".build/Narrate-$version.zip"

# Inner code first, then the app; hardened runtime and a secure timestamp are required for notarization.
find "$app/Contents/MacOS" -name '*.dylib' -exec codesign --force --options runtime --timestamp --sign "$identity" {} +
# Sparkle's helpers one by one, as its docs prescribe for Developer ID (no --deep).
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
sign() { codesign --force --options runtime --timestamp --sign "$identity" "$@"; }
sign "$sparkle/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
spctl --assess --type execute --verbose=2 "$app"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
shasum -a 256 "$zip"

# Sparkle feed: sign the zip with the EdDSA key in the keychain (scripts/../generate_keys --account
# narrate made it) and put the release at the top of docs/appcast.xml, served by GitHub Pages.
signature="$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account narrate "$zip")"
item="    <item>
      <title>Narrate $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$version</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/djui/narrate/releases/tag/v$version</sparkle:releaseNotesLink>
      <enclosure url=\"https://github.com/djui/narrate/releases/download/v$version/Narrate-$version.zip\" type=\"application/octet-stream\" $signature/>
    </item>"
ITEM="$item" awk '{ print } /<!-- items -->/ { print ENVIRON["ITEM"] }' docs/appcast.xml > docs/appcast.xml.new && mv docs/appcast.xml.new docs/appcast.xml
echo "updated docs/appcast.xml; commit and push it after the release is published"

if [ "$publish" = "--publish" ]; then
  gh release create "v$version" "$zip" --title "Narrate $version" --generate-notes
fi
echo "$zip"
