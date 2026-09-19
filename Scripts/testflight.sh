#!/bin/bash
# Archive Bookrest for iOS and upload the build to TestFlight.
#
# Required environment:
#   TEAM_ID          Apple Developer team ID (10 characters, from developer.apple.com → Membership)
#
# Authentication — use ONE of these:
#   A) App Store Connect API key (preferred; works unattended)
#        ASC_KEY_ID      the key's ID, e.g. 2X9R4HXF34
#        ASC_ISSUER_ID   the issuer UUID shown above the key list
#        ASC_KEY_PATH    path to the AuthKey_<KEY_ID>.p8 file
#   B) Apple ID with an app-specific password
#        ASC_APPLE_ID    your Apple ID email
#        ASC_APP_PASSWORD  an app-specific password from appleid.apple.com
#
# Optional:
#   BUILD_NUMBER     defaults to a UTC timestamp, which always increases
#   CARPLAY=1        sign with the CarPlay Audio entitlement (requires the App ID to
#                    have CarPlay enabled; the provisioning profile must then carry
#                    com.apple.developer.carplay-audio)
#
# Nothing here is stored in the repo; secrets stay in your shell or keychain.

set -euo pipefail

cd "$(dirname "$0")/.."

: "${TEAM_ID:?Set TEAM_ID to your Apple Developer team ID}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"

ENTITLEMENTS_ARG=()
if [ "${CARPLAY:-0}" = "1" ]; then
  ENTITLEMENTS_ARG=(CODE_SIGN_ENTITLEMENTS=Bookrest/Resources/Bookrest-iOS-CarPlay.entitlements)
  echo "▸ CarPlay Audio entitlement enabled for this build"
fi

# xcodebuild needs the API key too, not just altool: -allowProvisioningUpdates uses
# it to create the signing certificate and provisioning profile unattended.
XCODE_AUTH=()
if [ -n "${ASC_KEY_ID:-}" ]; then
  KEY_ABS="$(cd "$(dirname "${ASC_KEY_PATH:?Set ASC_KEY_PATH}")" && pwd)/$(basename "$ASC_KEY_PATH")"
  XCODE_AUTH=(-authenticationKeyPath "$KEY_ABS"
              -authenticationKeyID "$ASC_KEY_ID"
              -authenticationKeyIssuerID "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID}")
fi

BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/Bookrest.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
OPTIONS="$BUILD_DIR/ExportOptions.plist"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
sed "s/__TEAM_ID__/$TEAM_ID/" Scripts/ExportOptions.plist > "$OPTIONS"

# Regenerate the project so a fresh checkout works without opening Xcode.
command -v xcodegen >/dev/null && xcodegen generate

echo "▸ Archiving (build $BUILD_NUMBER)"
xcodebuild \
  -project Bookrest.xcodeproj \
  -scheme Bookrest \
  -sdk iphoneos \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  "${XCODE_AUTH[@]}" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  "${ENTITLEMENTS_ARG[@]}" \
  archive

echo "▸ Exporting signed .ipa"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OPTIONS" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates \
  "${XCODE_AUTH[@]}"

IPA="$(find "$EXPORT_DIR" -name '*.ipa' | head -1)"
[ -n "$IPA" ] || { echo "No .ipa produced"; exit 1; }
echo "▸ Built $IPA"

echo "▸ Validating before upload"
if [ -n "${ASC_KEY_ID:-}" ]; then
  # altool looks for the key in ./private_keys or ~/.appstoreconnect/private_keys.
  # Skip the copy when ASC_KEY_PATH already points at that location — cp exits 1 on
  # "same file", which under `set -e` would abort the run after a successful archive.
  mkdir -p ~/.appstoreconnect/private_keys
  KEY_DEST="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
  if [ "$KEY_ABS" != "$KEY_DEST" ]; then
    cp "$KEY_ABS" "$KEY_DEST"
  fi
  AUTH=(--apiKey "$ASC_KEY_ID" --apiIssuer "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID}")
else
  AUTH=(--username "${ASC_APPLE_ID:?Set ASC_KEY_ID or ASC_APPLE_ID}" \
        --password "${ASC_APP_PASSWORD:?Set ASC_APP_PASSWORD}")
fi

xcrun altool --validate-app -f "$IPA" -t ios "${AUTH[@]}"

echo "▸ Uploading to TestFlight"
xcrun altool --upload-app -f "$IPA" -t ios "${AUTH[@]}"

echo "✓ Uploaded build $BUILD_NUMBER. Processing in App Store Connect usually takes 5–15 minutes."
