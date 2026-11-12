#!/bin/bash
# Creates a self-signed code-signing identity in your login keychain.
# Signing every build with the same identity means macOS keeps the Accessibility and
# Screen Recording permissions across rebuilds (ad-hoc signatures change every build).
set -euo pipefail
NAME="${1:-RapidTab Local Signing}"

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "Identity \"$NAME\" already exists."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
PASS=$(openssl rand -hex 12)
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PASS"
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$PASS" -T /usr/bin/codesign
echo "Created signing identity \"$NAME\"."
