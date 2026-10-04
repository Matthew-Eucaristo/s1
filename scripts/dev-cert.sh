#!/usr/bin/env bash
# Create a stable self-signed code-signing identity ("S1 Dev Cert") for local
# development and trust it for codesigning in the login keychain.
#
# Why: ad-hoc signatures make TCC (Accessibility, Screen Recording, Input
# Monitoring, Microphone) key its grants on the binary's cdhash — which changes
# on EVERY rebuild, so every rebuild silently loses its grants. A stable cert
# gives TCC one identity to grant, so permissions survive rebuilds.
#
# Run once per machine: ./scripts/dev-cert.sh
# macOS will pop two GUI prompts (trust settings + keychain access) — approve both.
set -euo pipefail

NAME="${S1_SIGN_IDENTITY:-S1 Dev Cert}"
DIR="${TMPDIR:-/tmp}/s1-dev-cert"
mkdir -p "$DIR"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "identity '$NAME' already present — nothing to do"
    exit 0
fi

echo "creating self-signed codesigning cert '$NAME' (10y)…"
openssl req -x509 -newkey rsa:2048 \
    -keyout "$DIR/s1dev.key" -out "$DIR/s1dev.crt" \
    -days 3650 -nodes -subj "/CN=$NAME/" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null

# -legacy: macOS' `security import` expects SHA1-MAC PKCS12, not OpenSSL 3's
# default SHA256.
openssl pkcs12 -export -legacy \
    -inkey "$DIR/s1dev.key" -in "$DIR/s1dev.crt" \
    -out "$DIR/s1dev.p12" -passout pass:s1dev 2>/dev/null

security import "$DIR/s1dev.p12" -k ~/Library/Keychains/login.keychain-db \
    -P s1dev -T /usr/bin/codesign

echo "trusting for codesigning (a password dialog will appear — approve it)…"
security add-trusted-cert -k ~/Library/Keychains/login.keychain-db \
    -p codeSign "$DIR/s1dev.crt"

rm -rf "$DIR"
echo "done — make-app.sh will sign dist/S1.app with '$NAME' automatically"
echo "(override with S1_SIGN_IDENTITY=<your identity>)"
