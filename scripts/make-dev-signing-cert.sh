#!/bin/bash
# Creates the self-signed certificate that signs development builds and adds it to the login keychain.
#   scripts/make-dev-signing-cert.sh
# It belongs to no Apple account and stays on this Mac. Run it once: macOS ties the Screen Recording permission to it.
set -euo pipefail

NAME="Cornermark Dev Self-Signed"
OPENSSL=/usr/bin/openssl
DAYS=3650
KEYCHAIN="$(security default-keychain -d user | tr -d ' "')"

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "$NAME"; then
    echo "$NAME already exists"
    exit 0
fi

umask 077
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASSWORD="$("$OPENSSL" rand -hex 24)"
export CORNERMARK_P12_PASSWORD="$PASSWORD"

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=$NAME
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days "$DAYS" -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/$NAME.p12" -passout env:CORNERMARK_P12_PASSWORD
security import "$WORK/$NAME.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null

echo "created $NAME in $KEYCHAIN"
