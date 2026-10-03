#!/usr/bin/env bash
# One-time: creates a self-signed code-signing identity in a dedicated keychain so
# Tether.app has a STABLE identity. macOS privacy permissions (Screen Recording,
# Accessibility) are tied to that identity, so they survive rebuilds and redeploys.
# Ad-hoc signing ties them to the exact binary hash, which changes on every build.
#
# Creates (outside the repo, never committed):
#   ~/Library/Keychains/tether-signing.keychain-db
#   ~/.config/tether/signing-keychain-password   (chmod 600)
# Your login keychain is not touched. Safe to re-run: exits if already set up.
set -euo pipefail
NAME="Tether Signing"
KC="$HOME/Library/Keychains/tether-signing.keychain-db"
CONF="$HOME/.config/tether"
PWFILE="$CONF/signing-keychain-password"

if [[ -f "$KC" && -f "$PWFILE" ]]; then
  echo "✓ signing keychain already exists: $KC"
  exit 0
fi
# A keychain without its password file (interrupted earlier run) can't be used: start over.
if [[ -f "$KC" ]]; then security delete-keychain "$KC" 2>/dev/null || rm -f "$KC"; fi

mkdir -p "$CONF"; chmod 700 "$CONF"
umask 077
PW="$(openssl rand -hex 24)"
printf '%s' "$PW" > "$PWFILE"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
P12PW="$(openssl rand -hex 16)"
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout "pass:$P12PW" 2>/dev/null \
|| openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout "pass:$P12PW"

# Keep the user's keychain search list exactly as it was.
ORIG_LIST=()
while IFS= read -r line; do ORIG_LIST+=("$(echo "$line" | sed -E 's/^ *"(.*)"$/\1/')"); done < <(security list-keychains -d user)

security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"            # no auto-lock timeout
security unlock-keychain -p "$PW" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$P12PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null

security list-keychains -d user -s "${ORIG_LIST[@]}"
echo "✓ created signing identity \"$NAME\" in $KC"
