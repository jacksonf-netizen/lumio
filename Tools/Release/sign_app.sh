#!/bin/bash
# Signs a built Lumio.app inside out (frameworks, installer service, app) with the release team's
# certificate.
#
#   Tools/Release/sign_app.sh path/to/Lumio.app
#
# Which identity:
#   DEVELOPER_ID="Developer ID Application: …"   paid Apple Developer certificate (no warnings
#                                                 once notarized; see make_release.sh)
#   otherwise the "Apple Development" certificate of the team in RELEASE_TEAM_ID (project.yml),
#   which Xcode makes for a free Apple ID: Settings → Accounts → Manage Certificates → + →
#   Apple Development. SIGNING_IDENTITY (a name or SHA-1) picks a specific one.
#
# Why it matters: macOS ties the app's saved logins (Keychain) and its data folder to the app's
# signature. Signed by the same team every time, updates use both without asking. A build signed
# any other way (ad-hoc, self-signed, another team) makes every copy ask for the Mac password, and
# a different team also asks whether Lumio may access its own data. The team check below keeps a
# release from going out signed by the wrong certificate.
#
# Exits 2 when no suitable identity is available, leaving the app as built.
set -euo pipefail

APP=${1:?usage: sign_app.sh path/to/Lumio.app}
[ -d "$APP/Contents/MacOS" ] || { echo "sign_app: $APP isn't an app" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEAM=$(grep -E "^[[:space:]]+RELEASE_TEAM_ID:" "$ROOT/project.yml" | head -1 | sed -E 's/.*: *"?([^"]*)"?.*/\1/')

if [ -n "${DEVELOPER_ID:-}" ]; then
    IDENTITY="$DEVELOPER_ID"
elif [ -n "${SIGNING_IDENTITY:-}" ]; then
    IDENTITY="$SIGNING_IDENTITY"
else
    # The first valid Apple Development identity; the team is checked after signing.
    IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/"Apple Development: /{ split($0, a, " "); print a[2]; exit }')
    if [ -z "$IDENTITY" ]; then
        echo "sign_app: no Apple Development certificate in your Keychain (Xcode → Settings → Accounts → Manage Certificates)" >&2
        exit 2
    fi
fi

# A secure timestamp keeps the signature valid after the certificate expires.
sign() { codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$IDENTITY" "$1"; }

echo "==> Signing for team ${TEAM:-?}"
for framework in "$APP"/Contents/Frameworks/*.framework; do
    [ -e "$framework" ] && sign "$framework"
done
for service in "$APP"/Contents/XPCServices/*.xpc; do
    [ -e "$service" ] && sign "$service"
done
sign "$APP"

codesign --verify --deep --strict "$APP"
SIGNED_TEAM=$(codesign --display --verbose=2 "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [ -n "$TEAM" ] && [ "$SIGNED_TEAM" != "$TEAM" ]; then
    echo "sign_app: signed for team \"$SIGNED_TEAM\", but RELEASE_TEAM_ID is \"$TEAM\". Updates signed by another team make every copy ask for passwords and data access again." >&2
    exit 1
fi
if ! codesign --display --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox"; then
    echo "sign_app: $APP lost its sandbox entitlement while signing" >&2
    exit 1
fi
