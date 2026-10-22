#!/bin/bash
# Signs a built Lumio.app with a stable identity, inside out (frameworks, installer service, app).
#
#   Tools/Release/sign_app.sh path/to/Lumio.app
#
# Which identity:
#   DEVELOPER_ID="Developer ID Application: …"   paid Apple Developer certificate (no warnings
#                                                 once notarized; see make_release.sh)
#   otherwise "Lumio Release Signing"             the self-signed certificate made once by
#                                                 Tools/Release/make_signing_certificate.sh
#                                                 (SIGNING_IDENTITY overrides the name)
#
# Why it matters: macOS ties the Keychain items holding provider logins to the app's signature.
# Xcode's default "Sign to Run Locally" (ad-hoc) signature changes with every build, so after each
# update macOS would ask for your password before Lumio could read its saved logins. Signed with
# the same certificate every time, updates read them without asking.
#
# Exits 2 when neither identity is available, leaving the app as built.
set -euo pipefail

APP=${1:?usage: sign_app.sh path/to/Lumio.app}
[ -d "$APP/Contents/MacOS" ] || { echo "sign_app: $APP isn't an app" >&2; exit 1; }

if [ -n "${DEVELOPER_ID:-}" ]; then
    IDENTITY="$DEVELOPER_ID"
    TIMESTAMP=(--timestamp)
else
    IDENTITY="${SIGNING_IDENTITY:-Lumio Release Signing}"
    # Apple's timestamp service only countersigns Apple-issued certificates.
    TIMESTAMP=(--timestamp=none)
    # The certificate is self-signed, so macOS lists it as "not trusted"; codesign uses it anyway.
    if ! security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
        echo "sign_app: no \"$IDENTITY\" certificate in your Keychain (Tools/Release/make_signing_certificate.sh makes it)" >&2
        exit 2
    fi
fi

sign() { codesign --force --options runtime "${TIMESTAMP[@]}" --preserve-metadata=entitlements --sign "$IDENTITY" "$1"; }

echo "==> Signing with \"$IDENTITY\""
for framework in "$APP"/Contents/Frameworks/*.framework; do
    [ -e "$framework" ] && sign "$framework"
done
for service in "$APP"/Contents/XPCServices/*.xpc; do
    [ -e "$service" ] && sign "$service"
done
sign "$APP"

codesign --verify --deep --strict "$APP"
# A certificate-based designated requirement is what keeps Keychain access across updates.
if ! codesign --display -r- "$APP" 2>&1 | grep -q "certificate"; then
    echo "sign_app: $APP didn't get a certificate-based signature" >&2
    exit 1
fi
if ! codesign --display --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox"; then
    echo "sign_app: $APP lost its sandbox entitlement while signing" >&2
    exit 1
fi
