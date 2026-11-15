#!/bin/bash
# One-time: creates a self-signed code-signing certificate in its own keychain file
# (not your login keychain, no trust settings changed). make-dmg.sh then signs every
# build with it, so macOS keeps PaneBridge's Screen Recording / Accessibility
# permissions across updates. The key never leaves this Mac and is not in the repo.
set -euo pipefail

DIR="$HOME/Library/Application Support/PaneBridge-Signing"
KC="$DIR/signing.keychain-db"
NAME="PaneBridge Self-Signed"

if [ -f "$KC" ] && security find-identity -p codesigning "$KC" | grep -q "$NAME"; then
  echo "Signing identity already set up in $KC"
  exit 0
fi

mkdir -p "$DIR" && chmod 700 "$DIR"
cd "$DIR"
[ -f pw ] || { openssl rand -hex 24 > pw; chmod 600 pw; }
PW="$(cat pw)"

cat > cert.cnf <<'EOF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=PaneBridge Self-Signed
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null
# macOS can't read OpenSSL 3's default PKCS#12 encryption, so use the legacy format.
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -out id.p12 -passout pass:"$PW" -name "$NAME" 2>/dev/null \
  || openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:"$PW" -name "$NAME"

[ -f "$KC" ] || security create-keychain -p "$PW" "$KC"
security unlock-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"
security import id.p12 -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$KC" >/dev/null
rm -f key.pem id.p12

security find-identity -p codesigning "$KC"
echo "Done. Future builds from scripts/make-dmg.sh will be signed with this certificate."
