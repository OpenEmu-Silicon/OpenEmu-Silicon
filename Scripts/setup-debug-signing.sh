#!/usr/bin/env bash
# setup-debug-signing.sh — One-time setup: create the "OpenEmu Debug" code-signing certificate.
#
# Why: debug builds are signed ad hoc, so the signature changes on every build and macOS silently drops
# the Input Monitoring grant. Keyboards then stop working while controllers keep working. launch-debug.sh
# re-signs the app it launches with a certificate of this name so the grant survives rebuilds.
#
# Usage:
#   ./Scripts/setup-debug-signing.sh           # create it (asks for your login password once)
#   ./Scripts/setup-debug-signing.sh --check   # only report whether it exists; exit 0 if so
#
# This changes your login keychain, so an agent should not run it for you. Run it yourself, once per Mac.
# After it, grant Input Monitoring to the debug app one time and rebuilds will no longer revoke it.

set -euo pipefail

NAME="${OE_DEBUG_SIGN_IDENTITY:-OpenEmu Debug}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

have_identity() { security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$NAME\""; }

if [ "${1:-}" = "--check" ]; then
  if have_identity; then echo "ok    \"$NAME\" certificate is installed"; exit 0; fi
  echo "missing  no valid \"$NAME\" certificate. Run ./Scripts/setup-debug-signing.sh" >&2
  exit 1
fi

if have_identity; then echo "ok    \"$NAME\" certificate already exists, nothing to do"; exit 0; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/oe-signing.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS="$(uuidgen)"

cat > "$WORK/openssl.cnf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/openssl.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/id.p12" -passout "pass:$PASS" 2>/dev/null

security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
# Trusting the certificate for code signing is what makes it a "valid identity". macOS asks for your password here.
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

if have_identity; then
  echo "ok    created \"$NAME\". Next: rebuild, run ./Scripts/launch-debug.sh, then grant Input Monitoring once."
else
  echo "FAIL  the certificate was imported but is not listed as a valid code-signing identity." >&2
  echo "      Open Keychain Access, find \"$NAME\", and set Trust > Code Signing to Always Trust." >&2
  exit 1
fi
