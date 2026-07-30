#!/bin/zsh
set -euo pipefail

# Creates a stable, self-signed code-signing identity in the login keychain so
# BambuBar keeps a consistent code identity across rebuilds. macOS ties the
# Local Network privacy grant to the app's code signature; with ad-hoc signing
# (`codesign --sign -`) that identity changes on every build and the grant is
# lost, so the app can no longer reach the printers. A stable identity fixes
# that: you approve Local Network access once and it survives future builds.
#
# The certificate is self-signed and left UNTRUSTED — codesign can still use it
# to sign, and TCC keys the Local Network grant on the (now stable) signature.
# Nothing here needs your password; it only touches your login keychain.
#
# Idempotent: re-running is a no-op if the identity already exists.

IDENTITY_NAME="BambuBar Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    echo "Tożsamość podpisu już istnieje: $IDENTITY_NAME"
    exit 0
fi

WORK="$(mktemp -d /private/tmp/bambubar-signing.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/codesign.cnf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = BambuBar Local Signing
[ v3 ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/bb.key" -out "$WORK/bb.crt" -config "$WORK/codesign.cnf"

# LibreSSL's PKCS#12 MAC fails to verify under an empty password on import,
# so use a throwaway transport password that is discarded with $WORK.
openssl pkcs12 -export -out "$WORK/bb.p12" -inkey "$WORK/bb.key" -in "$WORK/bb.crt" \
    -name "$IDENTITY_NAME" -passout pass:bambubar

security import "$WORK/bb.p12" -k "$KEYCHAIN" -P bambubar -A -T /usr/bin/codesign

echo "Utworzono tożsamość podpisu: $IDENTITY_NAME"
security find-identity -p codesigning "$KEYCHAIN" | grep "$IDENTITY_NAME" || true
