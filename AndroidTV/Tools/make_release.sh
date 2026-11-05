#!/bin/bash
# Builds the Android TV release: AndroidTV/build/release/Lumio-AndroidTV.apk and its .sig.
#
#   AndroidTV/Tools/make_release.sh
#
# 1. The shared core for 32- and 64-bit ARM (release build), then the APK (R8, both CPU types).
# 2. Signed with the release key from the Keychain (AndroidTV/Tools/apk_signing_key.swift).
# 3. Checked: the certificate is the one in AndroidTV/signing-certificate.txt, the version is the
#    one in version.properties, and the size is within the plan's budget (50 MB).
# 4. Signed for the in-app updater with the release key the Mac uses (Tools/Release/sign_update.swift),
#    and that signature checked with the public key the apps carry.
#
# Tools/Release/publish.sh runs this; it can also be run on its own to try a release build.
set -euo pipefail
cd "$(dirname "$0")/../.."
source AndroidTV/Tools/env.sh > /dev/null

fail() { echo "make_release (Android): $1" >&2; exit 1; }
version() { grep -E "^$1=" version.properties | head -1 | cut -d= -f2 | tr -d '[:space:]'; }
setting() { grep -E "^[[:space:]]+$1:" Mac/project.yml | head -1 | sed -E 's/.*: *"?([^"]*)"?.*/\1/'; }

VERSION=$(version MARKETING_VERSION)
IFS=. read -r MAJOR MINOR PATCH <<< "$VERSION"
CODE=$((MAJOR * 1000000 + MINOR * 1000 + PATCH))
OUT="AndroidTV/build/release"
APK="$OUT/Lumio-AndroidTV.apk"
TOOLS="$ANDROID_HOME/build-tools/$(ls "$ANDROID_HOME/build-tools" | sort -V | tail -1)"
EXPECTED_CERT=$(grep -vE '^#|^$' AndroidTV/signing-certificate.txt | head -1)
PUBLIC_KEY=$(setting UPDATE_PUBLIC_KEY)
[ -n "$PUBLIC_KEY" ] || fail "UPDATE_PUBLIC_KEY is empty in Mac/project.yml"

rm -rf "$OUT" && mkdir -p "$OUT"

echo "==> Building the shared core (release, armv7 and aarch64)"
AndroidTV/Tools/build_core.sh

echo "==> Building the APK $VERSION ($CODE)"
(cd AndroidTV && ./gradlew -q --console=plain :app:clean :app:assembleRelease)
UNSIGNED=AndroidTV/app/build/outputs/apk/release/app-release-unsigned.apk
[ -f "$UNSIGNED" ] || fail "Gradle made no $UNSIGNED"
"$TOOLS/zipalign" -c -p 4 "$UNSIGNED" > /dev/null || {
    "$TOOLS/zipalign" -f -p 4 "$UNSIGNED" "$OUT/aligned.apk"
    UNSIGNED="$OUT/aligned.apk"
}

echo "==> Signing with the release key"
swift AndroidTV/Tools/apk_signing_key.swift sign "$UNSIGNED" "$APK" 2> /dev/null
rm -f "$OUT/aligned.apk" "$APK.idsig"

echo "==> Checking the APK"
# Whole outputs first: with pipefail, a grep that stops reading early fails the pipeline.
VERIFY=$("$TOOLS/apksigner" verify --print-certs -v "$APK")
CERT=$(echo "$VERIFY" | awk '/certificate SHA-256 digest/ { print $NF; exit }')
[ "$CERT" = "$EXPECTED_CERT" ] || fail "signed with certificate $CERT, expected $EXPECTED_CERT (AndroidTV/signing-certificate.txt)"
# v3 (Android 9+, and it allows rotating the key later). apksigner leaves out v2 when every
# supported Android version checks v3, as here (minSdk 28).
[[ "$VERIFY" == *"Verified using v3 scheme (APK Signature Scheme v3): true"* ]] || fail "no v3 signature"
BADGING=$("$TOOLS/aapt2" dump badging "$APK")
BADGING=${BADGING%%$'\n'*}
[[ "$BADGING" == *"name='com.jackson.lumio' versionCode='$CODE' versionName='$VERSION'"* ]] || fail "unexpected package line: $BADGING"
SIZE=$(stat -f %z "$APK")
[ "$SIZE" -le $((50 * 1024 * 1024)) ] || fail "the APK is $((SIZE / 1024 / 1024)) MB, over the 50 MB limit"
CONTENTS=$(unzip -l "$APK")
for abi in armeabi-v7a arm64-v8a; do
    [[ "$CONTENTS" == *"lib/$abi/liblumiocore.so"* ]] || fail "the APK has no core for $abi"
done

echo "==> Signing for the in-app updater"
swift Tools/Release/sign_update.swift sign "$APK" > "$APK.sig"
swift Tools/Release/sign_update.swift verify "$APK" "$APK.sig" "$PUBLIC_KEY" > /dev/null || fail "the update signature doesn't check out with UPDATE_PUBLIC_KEY"

echo "==> $APK: $VERSION ($CODE), $((SIZE / 1024 / 1024)) MB, certificate ${CERT:0:16}…"
