#!/bin/bash
# Builds Lumio (Release) and installs it as /Applications/Lumio.app, replacing any earlier copy
# (including one from before the app was renamed from IPTV Streamer). This is the copy to open, pin
# in the Dock and find in Spotlight; your providers, favorites and settings are kept (they live in
# the app's own data folder, not in the app).
#
#   Tools/install.sh
#
# Quit the app first. The build copy in build/DerivedData.noindex is hidden from Spotlight and
# unregistered afterwards, so only the installed app shows up.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Lumio"
# The app was called IPTV Streamer before; its old copies are removed so only one app shows up.
OLD_NAME="IPTV Streamer"
OLD_TARGET="/Applications/$OLD_NAME.app"
BUILT="build/DerivedData.noindex/Build/Products/Release/$NAME.app"
TARGET="/Applications/$NAME.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

for running in "$TARGET" "$OLD_TARGET"; do
    if pgrep -f "$running/Contents/MacOS/" > /dev/null; then
        echo "$(basename "$running" .app) is running from Applications. Quit it (⌘Q) and run this again." >&2
        exit 1
    fi
done

echo "==> Building $NAME (Release)"
xcodegen --quiet
LOG=$(mktemp -t iptv-install)
if ! xcodebuild -project IPTVStreamer.xcodeproj -scheme IPTVMac -configuration Release \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData.noindex build > "$LOG" 2>&1; then
    grep -E "error:" "$LOG" | head -20 >&2
    echo "Build failed; nothing was installed. Full log: $LOG" >&2
    exit 1
fi
rm -f "$LOG"
[ -d "$BUILT" ] || { echo "Build failed: $BUILT not found" >&2; exit 1; }

echo "==> Installing to $TARGET"
rm -rf "$TARGET"
ditto "$BUILT" "$TARGET"
# Signed like releases, so this copy and updates can read the saved logins without asking.
if ! Tools/Release/sign_app.sh "$TARGET" > /dev/null; then
    echo "    (left ad-hoc signed: macOS may ask for your password before Lumio can read its saved logins)"
fi
for old in "$OLD_TARGET" "$PWD/build/DerivedData.noindex/Build/Products/"*"/$OLD_NAME.app"; do
    rm -rf "$old"
    "$LSREGISTER" -u "$old" 2>/dev/null || true
done
"$LSREGISTER" -u "$PWD/$BUILT" 2>/dev/null || true
"$LSREGISTER" -f "$TARGET"
echo "==> Done. Open it from Applications, Launchpad or Spotlight."
