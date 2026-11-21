#!/usr/bin/env bash
#
# build_dmg.sh
# Mac Doctor
#
# Archives Mac Doctor (Release), signs the .app bundle with Developer ID
# (or ad-hoc when run with --adhoc), notarizes with xcrun notarytool,
# staples the ticket, and builds a drag-to-Applications DMG with hdiutil.
#
# Usage:
#   # Paid Apple Developer account (Developer ID + Notarization + Staple):
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="macdoctor-notary" \
#   ./build_dmg.sh
#
#   # No paid Apple Developer account (ad-hoc signed DMG, skips notarization):
#   ./build_dmg.sh --adhoc
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via environment variables or edit directly)
# ---------------------------------------------------------------------------

DEVELOPER_ID="${DEVELOPER_ID:-Developer ID Application: YOUR NAME (TEAMID)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-macdoctor-notary}"

SCHEME="MacDoctor"
PROJECT="MacDoctor.xcodeproj"
APP_NAME="Mac Doctor"
BUNDLE_ID="com.macdoctor.app"
ENTITLEMENTS="MacDoctor/Resources/MacDoctor.entitlements"

DIST_DIR="dist"
ARCHIVE_PATH="${DIST_DIR}/${SCHEME}.xcarchive"
EXPORT_DIR="${DIST_DIR}/export"
DMG_STAGING="${DIST_DIR}/dmg-staging"

ADHOC=false
SKIP_NOTARIZE=false

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

for arg in "$@"; do
    case "$arg" in
        --adhoc)
            ADHOC=true
            SKIP_NOTARIZE=true
            ;;
        --skip-notarize)
            SKIP_NOTARIZE=true
            ;;
        -h|--help)
            sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ ! -d "$PROJECT" ]]; then
    echo "Error: $PROJECT not found in $SCRIPT_DIR" >&2
    exit 1
fi

if [[ "$ADHOC" == false && "$DEVELOPER_ID" == *"YOUR NAME (TEAMID)"* ]]; then
    echo "Error: Set DEVELOPER_ID before running, or pass --adhoc for a local ad-hoc build." >&2
    echo "Example: DEVELOPER_ID=\"Developer ID Application: Jane Doe (ABCDE12345)\" ./build_dmg.sh" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: Clean staging directory and archive Release build
# ---------------------------------------------------------------------------

echo "==> Cleaning ${DIST_DIR}/"
rm -rf "$DIST_DIR"
mkdir -p "$EXPORT_DIR" "$DMG_STAGING"

echo "==> Archiving ${APP_NAME} (Release, arm64)"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    archive

ARCHIVED_APP="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
if [[ ! -d "$ARCHIVED_APP" ]]; then
    echo "Error: Expected archived app at ${ARCHIVED_APP}" >&2
    exit 1
fi

APP_PATH="${EXPORT_DIR}/${APP_NAME}.app"
cp -R "$ARCHIVED_APP" "$APP_PATH"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${APP_PATH}/Contents/Info.plist")"
DMG_NAME="MacDoctor-${VERSION}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"

echo "==> Packaged version ${VERSION} (${BUILD_NUMBER})"

# ---------------------------------------------------------------------------
# Step 2: Code signing
# ---------------------------------------------------------------------------

if [[ "$ADHOC" == true ]]; then
    echo "==> Ad-hoc signing ${APP_NAME}.app (Hardened Runtime disabled for ad-hoc)"
    /usr/bin/codesign \
        --force \
        --deep \
        --sign "-" \
        --entitlements "$ENTITLEMENTS" \
        "$APP_PATH"
else
    echo "==> Signing ${APP_NAME}.app with: ${DEVELOPER_ID}"
    /usr/bin/codesign \
        --force \
        --deep \
        --options runtime \
        --timestamp \
        --sign "$DEVELOPER_ID" \
        --entitlements "$ENTITLEMENTS" \
        "$APP_PATH"
fi

echo "==> Verifying code signature"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# ---------------------------------------------------------------------------
# Step 3: Notarize & staple the .app (Developer ID builds only)
# ---------------------------------------------------------------------------

if [[ "$SKIP_NOTARIZE" == false ]]; then
    NOTARY_ZIP="${DIST_DIR}/MacDoctor-${VERSION}-notarize.zip"
    echo "==> Creating archive for notarization: ${NOTARY_ZIP}"
    /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$NOTARY_ZIP"

    echo "==> Submitting to Apple Notary Service (profile: ${NOTARY_PROFILE})"
    xcrun notarytool submit "$NOTARY_ZIP" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    echo "==> Stapling notarization ticket to ${APP_NAME}.app"
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"

    rm -f "$NOTARY_ZIP"
else
    echo "==> Skipping notarization (--adhoc or --skip-notarize)"
fi

# ---------------------------------------------------------------------------
# Step 4: Build drag-to-Applications DMG
# ---------------------------------------------------------------------------

echo "==> Preparing DMG staging directory"
cp -R "$APP_PATH" "${DMG_STAGING}/${APP_NAME}.app"
ln -s /Applications "${DMG_STAGING}/Applications"

echo "==> Creating compressed DMG: ${DMG_PATH}"
/usr/bin/hdiutil create \
    -volname "${APP_NAME} ${VERSION}" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"

# ---------------------------------------------------------------------------
# Step 5: Sign, notarize, and staple the DMG (Developer ID builds only)
# ---------------------------------------------------------------------------

if [[ "$SKIP_NOTARIZE" == false ]]; then
    echo "==> Signing DMG with: ${DEVELOPER_ID}"
    /usr/bin/codesign \
        --force \
        --timestamp \
        --sign "$DEVELOPER_ID" \
        "$DMG_PATH"

    echo "==> Submitting DMG to Apple Notary Service"
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    echo "==> Stapling notarization ticket to ${DMG_NAME}"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"

    echo "==> Gatekeeper assessment"
    /usr/sbin/spctl -a -vv -t open --context context:primary-signature "$DMG_PATH"
fi

echo ""
echo "Done! Output:"
echo "  App: ${APP_PATH}"
echo "  DMG: ${DMG_PATH}"
if [[ "$ADHOC" == true ]]; then
    echo ""
    echo "Note (ad-hoc build): On first launch, macOS Gatekeeper may block the app."
    echo "Open it once via System Settings -> Privacy & Security -> Open Anyway."
fi
