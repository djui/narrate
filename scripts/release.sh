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
find "$app/Contents/MacOS" -name '*.dylib' -exec codesign --force --options runtime --timestamp --sign "$identity" {} \;
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

if [ "$publish" = "--publish" ]; then
  gh release create "v$version" "$zip" --title "Narrate $version" --generate-notes
fi
echo "$zip"
