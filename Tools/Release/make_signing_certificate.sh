#!/bin/bash
# Makes the "Lumio Release Signing" certificate (once). Releases and Tools/install.sh sign the app
# with it, so the app's signature stays the same from one version to the next and macOS keeps
# letting it read its saved logins after an update (see sign_app.sh).
#
#   Tools/Release/make_signing_certificate.sh
#
# The certificate and its private key go into your login Keychain (Keychain Access → My
# Certificates). The key file is written to a private temporary folder only long enough to import
# it. Back it up with the update signing key (Docs/development.md, "Releasing"): signing with a
# new certificate later works, but everyone's copy would ask for their password once more.
#
# It's self-signed, not an Apple certificate, so it doesn't remove the first-launch "Open Anyway"
# step; only a paid Developer ID with notarization does that.
set -euo pipefail

NAME="Lumio Release Signing"
if security find-certificate -c "$NAME" > /dev/null 2>&1; then
    echo "A \"$NAME\" certificate is already in your Keychain." >&2
    exit 1
fi

WORK=$(mktemp -d -t lumio-signing)
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
O = Lumio
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
# 20 years: a code signature made without a timestamp is only valid while its certificate is.
openssl req -x509 -newkey rsa:3072 -nodes -days 7300 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2> /dev/null
PASSWORD=$(openssl rand -hex 16)
# -legacy: macOS can't import the newer PKCS#12 encryption OpenSSL 3 uses by default.
LEGACY=()
openssl pkcs12 -help 2>&1 | grep -q -- "-legacy" && LEGACY=(-legacy)
openssl pkcs12 -export "${LEGACY[@]}" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout "pass:$PASSWORD"
# Only codesign may use the key without asking.
security import "$WORK/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASSWORD" -T /usr/bin/codesign
echo "Made \"$NAME\". It's listed as not trusted (it's self-signed); codesign uses it anyway."
