#!/bin/bash
# Builds a release of Lumio into build/release/: a .dmg (for new installs), a .zip with its update
# signature (.zip.sig, which the app downloads to update itself), and SHA-256 checksums.
# Tools/Release/publish.sh runs this and puts the files on GitHub; run it alone to try a build.
#
#   Tools/Release/make_release.sh
#       Signed with the release team's Apple Development certificate (sign_app.sh explains why).
#       Other Macs open it the first time after System Settings → Privacy & Security → Open Anyway.
#
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" Tools/Release/make_release.sh
#       Signed for distribution with your Developer ID certificate (paid Apple Developer account).
#
#   DEVELOPER_ID="…" NOTARY_PROFILE=iptv-notary Tools/Release/make_release.sh
#       Also notarized and stapled, so it opens on any Mac without warnings. Create the profile once:
#       xcrun notarytool store-credentials iptv-notary --apple-id you@example.com --team-id TEAMID
#
# Before publishing, run Tools/check_secrets.py to make sure no credentials are in the repository.
set -euo pipefail
cd "$(dirname "$0")/../.."

setting() { grep -E "^[[:space:]]+$1:" project.yml | head -1 | sed -E 's/.*: *"?([^"]*)"?.*/\1/'; }
VERSION=$(setting MARKETING_VERSION)
BUILD=$(setting CURRENT_PROJECT_VERSION)
NAME="Lumio"
OUT="build/release"
APP="$OUT/$NAME.app"
ARCHIVE_BASE="Lumio-$VERSION"

echo "==> Building $NAME $VERSION ($BUILD)"
xcodegen --quiet
xcodebuild -project IPTVStreamer.xcodeproj -scheme IPTVMac -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData.noindex build \
    | grep -E "error:|warning: .*deprecated|BUILD" || true
BUILT="build/DerivedData.noindex/Build/Products/Release/$NAME.app"
[ -d "$BUILT" ] || { echo "Build failed: $BUILT not found" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"
ditto "$BUILT" "$APP"

# A build signed differently from the last release would make everyone's copy ask for their
# password before it can read its saved logins, so an ad-hoc build only goes out on purpose.
status=0
Tools/Release/sign_app.sh "$APP" || status=$?
if [ "$status" -eq 2 ] && [ "${ALLOW_ADHOC:-}" = 1 ]; then
    echo "==> ALLOW_ADHOC=1: leaving the ad-hoc signature"
elif [ "$status" -ne 0 ]; then
    echo "Not signed, so no release was made. Make the Apple Development certificate in Xcode" >&2
    echo "(Settings → Accounts → Manage Certificates), or set ALLOW_ADHOC=1 for a test build." >&2
    exit 1
fi

if [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "==> Notarizing (this takes a few minutes)"
    ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
    xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm "$OUT/notarize.zip"
fi

echo "==> Packaging"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ARCHIVE_BASE.zip"
STAGING="$OUT/dmg"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$NAME.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "$NAME $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$OUT/$ARCHIVE_BASE.dmg"
rm -rf "$STAGING"
if [ -n "${DEVELOPER_ID:-}" ]; then
    codesign --force --timestamp --sign "$DEVELOPER_ID" "$OUT/$ARCHIVE_BASE.dmg"
fi

# Only the archives stay, so there's no stray copy of the app for Spotlight and Launchpad to list
# next to the one in Applications (Tools/install.sh).
rm -rf "$APP"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for copy in "$PWD/$APP" "$PWD/$STAGING/$NAME.app" "$PWD/$BUILT" "/Volumes/$NAME $VERSION/$NAME.app"; do
    "$LSREGISTER" -u "$copy" 2>/dev/null || true
done

# The app only installs updates signed with the key whose public half is UPDATE_PUBLIC_KEY.
PUBLIC_KEY=$(setting UPDATE_PUBLIC_KEY)
if [ -n "$PUBLIC_KEY" ]; then
    echo "==> Signing the update archive"
    KEYCHAIN_KEY=$(swift Tools/Release/sign_update.swift public-key)
    if [ "$KEYCHAIN_KEY" != "$PUBLIC_KEY" ]; then
        echo "The signing key in your Keychain doesn't match UPDATE_PUBLIC_KEY in project.yml." >&2
        echo "Apps built with that key would refuse this update. Nothing was signed." >&2
        exit 1
    fi
    swift Tools/Release/sign_update.swift sign "$OUT/$ARCHIVE_BASE.zip" > "$OUT/$ARCHIVE_BASE.zip.sig"
else
    echo "==> UPDATE_PUBLIC_KEY is empty: no update signature (the app will offer the release page instead)."
fi

(cd "$OUT" && shasum -a 256 "$ARCHIVE_BASE.zip" "$ARCHIVE_BASE.dmg" > SHA256SUMS.txt)
echo "==> Done: $OUT"
cat "$OUT/SHA256SUMS.txt"
