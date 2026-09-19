#!/bin/bash
# Archive Bookrest for macOS and upload it to App Store Connect.
#
# Same environment as testflight.sh: TEAM_ID, plus ASC_KEY_ID / ASC_ISSUER_ID /
# ASC_KEY_PATH. BUILD_NUMBER defaults to a UTC timestamp.
#
# Export signing is manual, as on iOS: it names the "Bookrest Mac App Store" profile
# and needs the Apple Distribution and 3rd Party Mac Developer Installer identities
# in the keychain.

set -euo pipefail

cd "$(dirname "$0")/.."

: "${TEAM_ID:?Set TEAM_ID to your Apple Developer team ID}"
: "${ASC_KEY_ID:?Set ASC_KEY_ID}" "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID}" "${ASC_KEY_PATH:?Set ASC_KEY_PATH}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"

KEY_ABS="$(cd "$(dirname "$ASC_KEY_PATH")" && pwd)/$(basename "$ASC_KEY_PATH")"
XCODE_AUTH=(-authenticationKeyPath "$KEY_ABS"
            -authenticationKeyID "$ASC_KEY_ID"
            -authenticationKeyIssuerID "$ASC_ISSUER_ID")

BUILD_DIR="build/macos"
ARCHIVE="$BUILD_DIR/Bookrest.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
OPTIONS="$BUILD_DIR/ExportOptions.plist"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
sed "s/__TEAM_ID__/$TEAM_ID/" Scripts/ExportOptions-macOS.plist > "$OPTIONS"

command -v xcodegen >/dev/null && xcodegen generate

echo "▸ Archiving macOS (build $BUILD_NUMBER)"
xcodebuild \
  -project Bookrest.xcodeproj \
  -scheme Bookrest \
  -destination 'generic/platform=macOS' \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  "${XCODE_AUTH[@]}" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  archive

echo "▸ Exporting signed .pkg"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OPTIONS" \
  -exportPath "$EXPORT_DIR" \
  "${XCODE_AUTH[@]}"

PKG="$(find "$EXPORT_DIR" -name '*.pkg' | head -1)"
[ -n "$PKG" ] || { echo "No .pkg produced"; exit 1; }
echo "▸ Built $PKG"

mkdir -p ~/.appstoreconnect/private_keys
KEY_DEST="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
[ "$KEY_ABS" = "$KEY_DEST" ] || cp "$KEY_ABS" "$KEY_DEST"
AUTH=(--apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID")

echo "▸ Validating before upload"
xcrun altool --validate-app -f "$PKG" -t macos "${AUTH[@]}"

echo "▸ Uploading"
xcrun altool --upload-app -f "$PKG" -t macos "${AUTH[@]}"

echo "✓ Uploaded macOS build $BUILD_NUMBER."
