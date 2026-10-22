#!/bin/bash
# Publishes the version in project.yml as a GitHub release, which every copy of Lumio then offers
# to install the next time it opens.
#
#   1. Bump MARKETING_VERSION (and CURRENT_PROJECT_VERSION) in project.yml.
#   2. Move the notes under "## Unreleased" in CHANGELOG.md to a new "## X.Y.Z — date" section,
#      starting with a one- or two-sentence summary paragraph. They become the release notes; Lumio's
#      "update available" message shows only the summary (everything above the first "---").
#   3. Commit, then run:  Tools/Release/publish.sh
#
#   Tools/Release/publish.sh --print-notes   prints the release notes only (to fix a published
#                                             release: gh release edit vX.Y.Z --notes-file FILE)
#
# It checks for secrets, builds and signs the release (make_release.sh), tags it vX.Y.Z, pushes
# the branch and tag, and creates the GitHub release with the .dmg, .zip, .zip.sig and checksums.
# Needs the GitHub CLI signed in (`gh auth status`) and the signing key in your Keychain.
set -euo pipefail
cd "$(dirname "$0")/../.."

setting() { grep -E "^[[:space:]]+$1:" project.yml | head -1 | sed -E 's/.*: *"?([^"]*)"?.*/\1/'; }
fail() { echo "publish: $1" >&2; exit 1; }

VERSION=$(setting MARKETING_VERSION)
REPOSITORY=$(setting UPDATE_REPOSITORY)
TAG="v$VERSION"
OUT="build/release"
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

**Already have Lumio?** It offers this update the next time you open it (or use Lumio → Check for Updates…).

**New to Lumio?** It needs a Mac with Apple silicon (M1 or later) and macOS 14 or later.
1. Download **$BASE.dmg** below, open it and drag Lumio to Applications.
2. The first time, macOS says it can't check Lumio for malicious software. Click **Done**, open
   **System Settings → Privacy & Security**, scroll down, click **Open Anyway** next to Lumio and
   confirm.
   You only do this once; updates install without it.
3. Add your provider in Settings → Providers.

Source code for this version: [$TAG](https://github.com/$REPOSITORY/tree/$TAG). Third-party
components and their licences: [THIRD-PARTY-NOTICES.md](https://github.com/$REPOSITORY/blob/$TAG/THIRD-PARTY-NOTICES.md).
EOF

if [ "${1:-}" = "--print-notes" ]; then
    cat "$NOTES_FILE"
    exit 0
fi

[ -n "$REPOSITORY" ] || fail "UPDATE_REPOSITORY is empty in project.yml"
[ -n "$(setting UPDATE_PUBLIC_KEY)" ] || fail "UPDATE_PUBLIC_KEY is empty, so the app couldn't install this update"
command -v gh > /dev/null || fail "install the GitHub CLI first: brew install gh"
gh auth status > /dev/null 2>&1 || fail "sign in to GitHub first: gh auth login"
[ -z "$(git status --porcelain)" ] || fail "commit or stash your changes first (git status)"
[ "$(git branch --show-current)" = "main" ] || fail "publish from the main branch"
git rev-parse -q --verify "refs/tags/$TAG" > /dev/null && fail "$TAG already exists; bump MARKETING_VERSION in project.yml"
gh release view "$TAG" --repo "$REPOSITORY" > /dev/null 2>&1 && fail "a $TAG release already exists on GitHub"

echo "==> Checking for secrets"
python3 Tools/check_secrets.py

Tools/Release/make_release.sh
for file in "$BASE.dmg" "$BASE.zip" "$BASE.zip.sig" SHA256SUMS.txt; do
    [ -f "$OUT/$file" ] || fail "$OUT/$file is missing"
done

echo "==> Tagging $TAG and pushing"
git tag -a "$TAG" -m "Lumio $VERSION"
git push origin main "$TAG"

echo "==> Creating the GitHub release"
gh release create "$TAG" --repo "$REPOSITORY" --title "Lumio $VERSION" --notes-file "$NOTES_FILE" \
    "$OUT/$BASE.dmg" "$OUT/$BASE.zip" "$OUT/$BASE.zip.sig" "$OUT/SHA256SUMS.txt"
echo "==> Published: https://github.com/$REPOSITORY/releases/tag/$TAG"
