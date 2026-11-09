#!/usr/bin/env bash
# Creates the self-signed code-signing identity "Corral Local Signing" (once), for building from source
# without a Developer ID. bundle.sh signs local builds with it, so macOS privacy grants (Desktop,
# Documents, …) survive rebuilds: an ad-hoc signature changes every build and macOS then silently
# denies what was allowed before. The certificate holds only its name and stays untrusted: codesign doesn't need trust, and
# Gatekeeper ignores self-signed certificates either way.
#
# It lives in its own keychain (scripts/signing-keychain.sh): a key in the login keychain makes
# codesign ask for access on every build unless the login password is typed into the script.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing-keychain.sh

# Never replaces an existing keychain: a new certificate resets this Mac's privacy grants.
if [[ -e "$CORRAL_KEYCHAIN" ]]; then
    echo "$CORRAL_KEYCHAIN exists; delete it yourself to make a new identity." >&2; exit 1
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CORRAL_IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
P12=$(openssl rand -hex 16)
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout "pass:$P12" 2>/dev/null \
    || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout "pass:$P12"

# Keychain password: random, kept in the login keychain (created by `security`, which reads it back
# without a prompt).
PASS=$(openssl rand -hex 24)
security delete-generic-password -a "$CORRAL_KEYCHAIN_ACCOUNT" -s "$CORRAL_KEYCHAIN_SERVICE" >/dev/null 2>&1 || true
security add-generic-password -a "$CORRAL_KEYCHAIN_ACCOUNT" -s "$CORRAL_KEYCHAIN_SERVICE" -w "$PASS"
security create-keychain -p "$PASS" "$CORRAL_KEYCHAIN"
# No auto-lock while a long build runs; bundle.sh unlocks it each time anyway.
security set-keychain-settings "$CORRAL_KEYCHAIN"
security unlock-keychain -p "$PASS" "$CORRAL_KEYCHAIN"
security import "$TMP/id.p12" -k "$CORRAL_KEYCHAIN" -P "$P12" -T /usr/bin/codesign >/dev/null
# Lets codesign use the key without a dialog (needs the keychain's password, which we have).
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$CORRAL_KEYCHAIN" >/dev/null
corral_unlock_signing
echo "Done. Rebuild with scripts/bundle.sh --install; macOS asks for folder access once more, then remembers it."
