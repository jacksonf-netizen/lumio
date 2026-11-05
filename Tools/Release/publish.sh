#!/bin/bash
# Publishes the version in version.properties as a GitHub release, which every copy of Lumio then offers
# to install the next time it opens.
#
#   1. Bump MARKETING_VERSION (and CURRENT_PROJECT_VERSION) in version.properties.
#   2. Move the notes under "## Unreleased" in CHANGELOG.md to a new "## X.Y.Z — date" section,
#      starting with a one- or two-sentence summary paragraph. They become the release notes; Lumio's
#      "update available" message shows only the summary (everything above the first "---").
#   3. Commit, then run:  Tools/Release/publish.sh
#
#   Tools/Release/publish.sh --print-notes   prints the release notes only (to fix a published
#                                             release: gh release edit vX.Y.Z --notes-file FILE)
#
# It checks for secrets, builds and signs both apps (Mac/Tools/Release/make_release.sh and
# AndroidTV/Tools/make_release.sh), tags it vX.Y.Z, pushes the branch and tag, and creates the
# GitHub release with the Mac's .dmg, .zip and .zip.sig, Lumio-AndroidTV.apk and its .sig, and
# one SHA256SUMS.txt. Then it downloads the release and checks every file, and deletes the
# previous release (its tag stays).
#
# Every release carries both apps. The notes end with a hidden marker of the version in which each
# app's code last changed (worked out from git), so each app only offers the update when there's
# something new for it: <!-- lumio-changed: mac=X android=Y -->.
#
# Needs the GitHub CLI signed in (`gh auth status`), the update signing key and the APK signing key
# in your Keychain, and the Android tools (AndroidTV/Tools/env.sh).
set -euo pipefail
cd "$(dirname "$0")/../.."

setting() { grep -E "^[[:space:]]+$1:" Mac/project.yml | head -1 | sed -E 's/.*: *"?([^"]*)"?.*/\1/'; }
version() { grep -E "^$1=" version.properties | head -1 | cut -d= -f2 | tr -d '[:space:]'; }
fail() { echo "publish: $1" >&2; exit 1; }

VERSION=$(version MARKETING_VERSION)
REPOSITORY=$(setting UPDATE_REPOSITORY)
TAG="v$VERSION"
OUT="Mac/build/release"
BASE="Lumio-$VERSION"

# This version's section of CHANGELOG.md, without its heading.
NOTES=$(awk -v version="$VERSION" '
    /^## / { if (found) exit; if (index($0, "## " version) == 1) { found = 1; next } }
    found { print }
' CHANGELOG.md)
[ -n "$(echo "$NOTES" | tr -d '[:space:]')" ] || fail "add a \"## $VERSION\" section to CHANGELOG.md"

# The first paragraph is the summary the app shows; the rest goes below a "---" line.
SUMMARY=$(echo "$NOTES" | awk 'NF { found = 1 } found && !NF { exit } found { print }')
DETAILS=$(echo "$NOTES" | awk 'NF { started = 1 } started && !NF { past = 1 } past { print }')
[[ "$SUMMARY" != "- "* ]] || fail "start the $VERSION section with a short summary paragraph (the app shows only that)"

# The newest version (this one, or an earlier tag) in which these paths changed.
last_changed() {
    local newer="HEAD" newer_version="$VERSION" tag
    for tag in $(git tag -l 'v*' --sort=-v:refname); do
        [ "$tag" = "$TAG" ] && continue
        if ! git diff --quiet "$tag" "$newer" -- "$@"; then echo "$newer_version"; return; fi
        newer="$tag"
        newer_version="${tag#v}"
    done
    echo "$newer_version"
}
MAC_CHANGED=$(last_changed Mac Shared/LumioCore/Sources THIRD-PARTY-NOTICES.md)
ANDROID_CHANGED=$(last_changed AndroidTV/app AndroidTV/core-bridge AndroidTV/Tools Shared/LumioCore/Sources THIRD-PARTY-NOTICES.md)
MARKER="<!-- lumio-changed: mac=$MAC_CHANGED android=$ANDROID_CHANGED -->"

NOTES_FILE=$(mktemp -t lumio-notes)
trap 'rm -f "$NOTES_FILE"' EXIT
cat > "$NOTES_FILE" <<EOF
$SUMMARY

---
$DETAILS


**Lumio doesn't provide any content.** It includes no channels, streams, playlists or logins. You
need your own subscription from an IPTV provider and the Xtream Codes login they give you (server
address, username and password), and you're responsible for using Lumio only with services you're
entitled to.

**Already have Lumio?** It offers this update the next time you open it, if there's something new
for your device (on a Mac you can also use Lumio → Check for Updates…; on a TV, Settings → About).

**New to Lumio on a Mac?** It needs Apple silicon (M1 or later) and macOS 14 or later.
1. Download **$BASE.dmg** below, open it and drag Lumio to Applications.
2. The first time, macOS says it can't check Lumio for malicious software. Click **Done**, open
   **System Settings → Privacy & Security**, scroll down, click **Open Anyway** next to Lumio and
   confirm.
   You only do this once; updates install without it.
3. Add your provider in Settings → Providers.

**New to Lumio on Android TV or Google TV?** It needs Android 9 or later.
1. Install **Downloader** (by AFTVnews) from the Google Play Store on the TV.
2. Allow Downloader to install apps: Settings → Apps → Security & restrictions → Unknown sources →
   Downloader.
3. Open Downloader and enter this address:
   \`https://github.com/$REPOSITORY/releases/latest/download/Lumio-AndroidTV.apk\`
   Install, then open Lumio and add your provider in Settings → Providers.
   Lumio updates itself after that (Android asks you to confirm each update).

Source code for this version: [$TAG](https://github.com/$REPOSITORY/tree/$TAG). Third-party
components and their licences: [THIRD-PARTY-NOTICES.md](https://github.com/$REPOSITORY/blob/$TAG/THIRD-PARTY-NOTICES.md).

$MARKER
EOF

if [ "${1:-}" = "--print-notes" ]; then
    cat "$NOTES_FILE"
    exit 0
fi

[ -n "$REPOSITORY" ] || fail "UPDATE_REPOSITORY is empty in Mac/project.yml"
[ -n "$(setting UPDATE_PUBLIC_KEY)" ] || fail "UPDATE_PUBLIC_KEY is empty, so the app couldn't install this update"
command -v gh > /dev/null || fail "install the GitHub CLI first: brew install gh"
gh auth status > /dev/null 2>&1 || fail "sign in to GitHub first: gh auth login"
[ -z "$(git status --porcelain)" ] || fail "commit or stash your changes first (git status)"
[ "$(git branch --show-current)" = "main" ] || fail "publish from the main branch"
git rev-parse -q --verify "refs/tags/$TAG" > /dev/null && fail "$TAG already exists; bump MARKETING_VERSION in version.properties"
gh release view "$TAG" --repo "$REPOSITORY" > /dev/null 2>&1 && fail "a $TAG release already exists on GitHub"
[ "$MAC_CHANGED" = "$VERSION" ] || [ "$ANDROID_CHANGED" = "$VERSION" ] || fail "neither app changed since the last release ($MARKER)"
PREVIOUS=$(gh release list --repo "$REPOSITORY" --limit 1 --json tagName --jq '.[0].tagName // empty')

echo "==> Checking for secrets"
python3 Tools/check_secrets.py

Mac/Tools/Release/make_release.sh
for file in "$BASE.dmg" "$BASE.zip" "$BASE.zip.sig"; do
    [ -f "$OUT/$file" ] || fail "$OUT/$file is missing"
done
AndroidTV/Tools/make_release.sh
ANDROID_OUT="AndroidTV/build/release"
for file in Lumio-AndroidTV.apk Lumio-AndroidTV.apk.sig; do
    [ -f "$ANDROID_OUT/$file" ] || fail "$ANDROID_OUT/$file is missing"
done
# One checksum file for everything.
{ (cd "$OUT" && shasum -a 256 "$BASE.zip" "$BASE.dmg"); (cd "$ANDROID_OUT" && shasum -a 256 Lumio-AndroidTV.apk); } > "$OUT/SHA256SUMS.txt"
echo "==> Marker: $MARKER"

echo "==> Tagging $TAG and pushing"
git tag -a "$TAG" -m "Lumio $VERSION"
git push origin main "$TAG"

echo "==> Creating the GitHub release"
gh release create "$TAG" --repo "$REPOSITORY" --title "Lumio $VERSION" --notes-file "$NOTES_FILE" \
    "$OUT/$BASE.dmg" "$OUT/$BASE.zip" "$OUT/$BASE.zip.sig" \
    "$ANDROID_OUT/Lumio-AndroidTV.apk" "$ANDROID_OUT/Lumio-AndroidTV.apk.sig" "$OUT/SHA256SUMS.txt"
echo "==> Published: https://github.com/$REPOSITORY/releases/tag/$TAG"

echo "==> Checking the published files"
CHECK=$(mktemp -d -t lumio-check)
gh release download "$TAG" --repo "$REPOSITORY" --dir "$CHECK"
(cd "$CHECK" && shasum -a 256 -c SHA256SUMS.txt)
PUBLIC_KEY=$(setting UPDATE_PUBLIC_KEY)
swift Tools/Release/sign_update.swift verify "$CHECK/$BASE.zip" "$CHECK/$BASE.zip.sig" "$PUBLIC_KEY"
swift Tools/Release/sign_update.swift verify "$CHECK/Lumio-AndroidTV.apk" "$CHECK/Lumio-AndroidTV.apk.sig" "$PUBLIC_KEY"
source AndroidTV/Tools/env.sh > /dev/null
TOOLS="$ANDROID_HOME/build-tools/$(ls "$ANDROID_HOME/build-tools" | sort -V | tail -1)"
CERT=$("$TOOLS/apksigner" verify --print-certs "$CHECK/Lumio-AndroidTV.apk")
CERT=$(echo "$CERT" | awk '/certificate SHA-256 digest/ { print $NF; exit }')
[ "$CERT" = "$(grep -vE '^#|^$' AndroidTV/signing-certificate.txt | head -1)" ] || fail "the published APK has certificate $CERT"
BADGING=$("$TOOLS/aapt2" dump badging "$CHECK/Lumio-AndroidTV.apk")
[[ "${BADGING%%$'\n'*}" == *"versionName='$VERSION'"* ]] || fail "the published APK isn't version $VERSION"
# The address Downloader uses must serve this APK.
curl -fsSL "https://github.com/$REPOSITORY/releases/latest/download/Lumio-AndroidTV.apk" -o "$CHECK/latest.apk"
cmp -s "$CHECK/latest.apk" "$CHECK/Lumio-AndroidTV.apk" || fail "releases/latest/download/Lumio-AndroidTV.apk isn't this release's APK"
rm -rf "$CHECK"
echo "==> Published files check out"

# One release on GitHub at a time: the previous one goes, its tag stays.
if [ -n "$PREVIOUS" ] && [ "$PREVIOUS" != "$TAG" ]; then
    echo "==> Deleting the $PREVIOUS release (keeping its tag)"
    gh release delete "$PREVIOUS" --repo "$REPOSITORY" --yes
fi
