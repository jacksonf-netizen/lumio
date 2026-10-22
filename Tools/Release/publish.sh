#!/bin/bash
# Publishes the version in project.yml as a GitHub release, which every copy of Lumio then offers
# to install the next time it opens.
#
#   1. Bump MARKETING_VERSION (and CURRENT_PROJECT_VERSION) in project.yml.
#   2. Move the notes under "## Unreleased" in CHANGELOG.md to a new "## X.Y.Z — date" section.
#      They become the release notes (and what Lumio shows in its "update available" message).
#   3. Commit, then run:  Tools/Release/publish.sh
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

[ -n "$REPOSITORY" ] || fail "UPDATE_REPOSITORY is empty in project.yml"
[ -n "$(setting UPDATE_PUBLIC_KEY)" ] || fail "UPDATE_PUBLIC_KEY is empty, so the app couldn't install this update"
command -v gh > /dev/null || fail "install the GitHub CLI first: brew install gh"
gh auth status > /dev/null 2>&1 || fail "sign in to GitHub first: gh auth login"
[ -z "$(git status --porcelain)" ] || fail "commit or stash your changes first (git status)"
[ "$(git branch --show-current)" = "main" ] || fail "publish from the main branch"
git rev-parse -q --verify "refs/tags/$TAG" > /dev/null && fail "$TAG already exists; bump MARKETING_VERSION in project.yml"
gh release view "$TAG" --repo "$REPOSITORY" > /dev/null 2>&1 && fail "a $TAG release already exists on GitHub"

# This version's section of CHANGELOG.md, without its heading.
NOTES=$(awk -v version="$VERSION" '
    /^## / { if (found) exit; if (index($0, "## " version) == 1) { found = 1; next } }
    found { print }
' CHANGELOG.md)
[ -n "$(echo "$NOTES" | tr -d '[:space:]')" ] || fail "add a \"## $VERSION\" section to CHANGELOG.md"

echo "==> Checking for secrets"
python3 Tools/check_secrets.py

Tools/Release/make_release.sh
for file in "$BASE.dmg" "$BASE.zip" "$BASE.zip.sig" SHA256SUMS.txt; do
    [ -f "$OUT/$file" ] || fail "$OUT/$file is missing"
done

NOTES_FILE=$(mktemp -t lumio-notes)
trap 'rm -f "$NOTES_FILE"' EXIT
cat > "$NOTES_FILE" <<EOF
$NOTES

---

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

echo "==> Tagging $TAG and pushing"
git tag -a "$TAG" -m "Lumio $VERSION"
git push origin main "$TAG"

echo "==> Creating the GitHub release"
gh release create "$TAG" --repo "$REPOSITORY" --title "Lumio $VERSION" --notes-file "$NOTES_FILE" \
    "$OUT/$BASE.dmg" "$OUT/$BASE.zip" "$OUT/$BASE.zip.sig" "$OUT/SHA256SUMS.txt"
echo "==> Published: https://github.com/$REPOSITORY/releases/tag/$TAG"
