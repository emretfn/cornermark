#!/bin/bash
# Creates the self-signed certificate that signs release builds and stores it as GitHub secrets.
#   scripts/make-signing-cert.sh <backup.p12>
# Keeps a password-protected copy at <backup.p12>, outside the repository. Prints no secret.
# macOS ties the Screen Recording permission to this certificate, so a new one makes users grant it once more.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="emretfn/cornermark"
OPENSSL=/usr/bin/openssl
DAYS=3650

if [ "$#" -ne 1 ]; then sed -n '3,3p' "$0" >&2; exit 2; fi
BACKUP_DIR="$(cd "$(dirname "$1")" && pwd)"
BACKUP="$BACKUP_DIR/$(basename "$1")"
case "$BACKUP_DIR/" in
    "$ROOT"/*) echo "$BACKUP is inside the repository" >&2; exit 2 ;;
esac
if [ -e "$BACKUP" ]; then echo "$BACKUP already exists" >&2; exit 2; fi
gh auth status -h github.com >/dev/null

read -rsp "Password for the backup (store it in your password manager): " PASSWORD; echo
read -rsp "Repeat the password: " REPEAT; echo
if [ "$PASSWORD" != "$REPEAT" ]; then echo "the passwords differ" >&2; exit 1; fi
if [ "${#PASSWORD}" -lt 12 ]; then echo "use at least 12 characters" >&2; exit 1; fi
export CORNERMARK_P12_PASSWORD="$PASSWORD"

umask 077
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=Cornermark Self-Signed
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days "$DAYS" -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -name "Cornermark Self-Signed" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$BACKUP" -passout env:CORNERMARK_P12_PASSWORD

base64 -i "$BACKUP" | gh secret set CORNERMARK_CERT_P12 --repo "$REPO"
printf '%s' "$PASSWORD" | gh secret set CORNERMARK_CERT_PASSWORD --repo "$REPO"

echo "secrets set on $REPO"
echo "backup at $BACKUP"
"$OPENSSL" x509 -in "$WORK/cert.pem" -noout -subject -enddate -fingerprint -sha1
