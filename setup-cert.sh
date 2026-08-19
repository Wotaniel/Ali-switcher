#!/bin/bash
# Creates a self-signed code-signing certificate (run once).
# Stable signature = TCC permissions survive rebuilds.
set -euo pipefail

CERT_NAME="AliSwitcher Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "OK: certificate already exists"
    exit 0
fi

security delete-certificate -c "$CERT_NAME" "$KEYCHAIN" 2>/dev/null || true

echo "Creating certificate $CERT_NAME ..."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# LibreSSL-compatible: extensions via file, not -addext
openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/req.csr" \
    -subj "/CN=$CERT_NAME/O=AliSwitcher" 2>/dev/null

cat > "$TMP/ext.cnf" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=digitalSignature
extendedKeyUsage=codeSigning
EOF

openssl x509 -req -in "$TMP/req.csr" -signkey "$TMP/key.pem" \
    -out "$TMP/cert.pem" -days 3650 -extfile "$TMP/ext.cnf" 2>/dev/null

openssl pkcs12 -export \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout pass:ali 2>/dev/null

security import "$TMP/cert.p12" -k "$KEYCHAIN" -P ali \
    -T /usr/bin/codesign -T /usr/bin/security 2>/dev/null

# Доверие: codesign видит только доверенные identity
security add-trusted-cert -r trustRoot -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null

security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo "OK: certificate created and trusted"
security find-identity -v -p codesigning | grep "$CERT_NAME"
