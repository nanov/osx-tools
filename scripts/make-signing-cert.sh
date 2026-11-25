#!/bin/zsh
# Create a self-signed code-signing identity, "Nanov OSX Utils Dev", in the login keychain.
# Builds signed with it keep the same identity, so macOS keeps the Accessibility grant
# across rebuilds. Remove it any time in Keychain Access (search "Nanov OSX Utils Dev").
set -euo pipefail
name="Nanov OSX Utils Dev"

if security find-identity -p codesigning | grep -q "$name"; then
  echo "\"$name\" already exists."
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/cfg" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
  -out "$tmp/id.p12" -passout pass:tmp -name "$name"

# Let codesign use the key without prompting on every build.
security import "$tmp/id.p12" -k ~/Library/Keychains/login.keychain-db -P tmp -T /usr/bin/codesign
# Trust it for code signing (macOS asks for your password here).
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$tmp/cert.pem"

security find-identity -p codesigning | grep "$name"
echo "Done. ./scripts/build.sh now signs with \"$name\"."
