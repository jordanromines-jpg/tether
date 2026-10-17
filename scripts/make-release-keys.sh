#!/usr/bin/env bash
# Makes the two keys for Tether downloads. Run once, on the Mac that approves releases (the Mac Studio):
#
#   1. The update key (Ed25519, Sparkle's EdDSA). Every installed Tether only accepts an update signed
#      with it. It lives in a dedicated keychain on this Mac and never goes to GitHub.
#   2. The release signing identity ("Tether Release", self-signed). Every download is code-signed with
#      it, so macOS keeps a download's permissions across updates. It goes into one GitHub secret.
#
# Never overwrites an existing update key: losing it means installed copies can never update again.
# Safe to re-run: it re-checks the backup export and prints the same instructions.
#
#   scripts/make-release-keys.sh            make what's missing, check the backup, print what Jordan does
#   scripts/make-release-keys.sh --check    make nothing; exit 1 unless both keys exist and the backup restores
#
# Creates (outside the repo, never committed):
#   ~/Library/Keychains/tether-release.keychain-db       the update key (generic password tether-update-key)
#                                                         and the signing identity (kept here so the secret can be remade)
#   ~/.config/tether/release/keychain-password           that keychain's password (chmod 600)
#   ~/.config/tether/release/update-public-key.txt       the update key's public half (goes in Info.plist)
#   ~/.config/tether/release/update-key-backup.txt       the update key, for your password manager (chmod 600)
#   ~/.config/tether/release/release-cert.pem            the signing identity's certificate (public)
#   ~/.config/tether/release/release-cert.sha256         its fingerprint, which release-approve.sh checks
#   ~/.config/tether/release/github-secret.txt           the signing identity for the GitHub secret (chmod 600)
set -euo pipefail
CHECK=0
case "${1:-}" in
  "") ;;
  --check) CHECK=1 ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF="$HOME/.config/tether/release"
KC="$HOME/Library/Keychains/tether-release.keychain-db"
PWFILE="$CONF/keychain-password"
SERVICE="tether-update-key"
ACCOUNT="ed25519"
NAME="Tether Release"
CERT_DAYS=7300   # 20 years: a new certificate would make every Mac grant the permissions again
SECRET_NAME="TETHER_RELEASE_IDENTITY"
OPENSSL=/usr/bin/openssl
REPO="$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#^.*github\.com[:/]##')"
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || REPO="jordanromines-jpg/tether"

die() { echo "✗ $*" >&2; exit 1; }
missing() { [[ $CHECK -eq 0 ]] || die "$* (run scripts/make-release-keys.sh without --check to make it)"; }
umask 077
mkdir -p "$CONF"; chmod 700 "$CONF"
TMP="$(mktemp -d)"
SCRATCH_KC="$TMP/restore-check.keychain-db"
ORIG_LIST=()
while IFS= read -r line; do ORIG_LIST+=("$(echo "$line" | sed -E 's/^ *"(.*)"$/\1/')"); done < <(security list-keychains -d user)
restore_list() { security list-keychains -d user -s ${ORIG_LIST[@]+"${ORIG_LIST[@]}"}; }
cleanup() {
  security delete-keychain "$SCRATCH_KC" 2>/dev/null || true
  restore_list
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- Tools: Sparkle's sign_update (from the pinned package) and a small Ed25519 helper (CryptoKit).
echo "› finding Sparkle's tools"
swift package resolve --package-path "$ROOT/agent" >/dev/null
SIGN_UPDATE="$ROOT/agent/.build/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$SIGN_UPDATE" ]] || die "Sparkle's sign_update not found at $SIGN_UPDATE"
cat > "$TMP/ed.swift" <<'SWIFT'
import CryptoKit
import Foundation
// new: print a new private key (base64 seed). public: read a seed on stdin, print its public key.
// verify <public> <signature> <file>: exit 0 only if the signature is valid.
let a = CommandLine.arguments
func b64(_ s: String) -> Data { guard let d = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)) else { exit(2) }; return d }
switch a.count > 1 ? a[1] : "" {
case "new": print(Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())
case "public":
    guard let line = readLine(), let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: b64(line)) else { exit(2) }
    print(k.publicKey.rawRepresentation.base64EncodedString())
case "verify":
    guard a.count == 5, let k = try? Curve25519.Signing.PublicKey(rawRepresentation: b64(a[2])),
          let file = try? Data(contentsOf: URL(fileURLWithPath: a[4])) else { exit(2) }
    exit(k.isValidSignature(b64(a[3]), for: file) ? 0 : 1)
default: exit(2)
}
SWIFT
swiftc -O "$TMP/ed.swift" -o "$TMP/ed" 2>/dev/null || die "couldn't build the Ed25519 helper (needs Apple's developer tools)"
ED="$TMP/ed"

# --- The dedicated keychain (unlocked from its password file, so approvals work over SSH too).
if [[ ! -f "$KC" ]]; then
  missing "no release keychain at $KC"
  [[ ! -f "$PWFILE" ]] || die "$PWFILE exists without its keychain: check before going on"
  openssl rand -hex 24 | tr -d '\n' > "$PWFILE"
  security create-keychain -p "$(cat "$PWFILE")" "$KC"
  security set-keychain-settings "$KC"   # no auto-lock timeout
  echo "› created $KC"
fi
[[ -f "$PWFILE" ]] || die "the keychain exists but $PWFILE is missing"
security unlock-keychain -p "$(cat "$PWFILE")" "$KC"
restore_list   # creating a keychain adds it to the list: keep the user's as it was

# Reads or writes the update key through stdin, so it never appears in a process list.
read_key() { security find-generic-password -s "$SERVICE" -a "$ACCOUNT" -w "$1" 2>/dev/null; }
store_key() {   # $1 = keychain; the key on stdin
  local key; key="$(cat)"
  printf 'add-generic-password -s %s -a %s -l "Tether update key" -w %s %s\n' "$SERVICE" "$ACCOUNT" "$key" "$1" | security -i >/dev/null
}

# --- The update key: made once, never replaced.
if read_key "$KC" >/dev/null; then
  echo "✓ the update key is already in $KC (kept as it is)"
else
  missing "no update key in $KC"
  "$ED" new | store_key "$KC"
  echo "✓ made the update key in $KC"
fi
PUBLIC="$(read_key "$KC" | "$ED" public)" || die "couldn't read the update key back from $KC"
printf '%s\n' "$PUBLIC" > "$CONF/update-public-key.txt"; chmod 644 "$CONF/update-public-key.txt"

# --- The backup export, proved restorable: import it into a scratch keychain, sign with it there,
# and check the signature against the public key of the key in the real keychain.
# After G-1 the file is gone (it's in the password manager), so --check then rebuilds it in $TMP only.
BACKUP="$CONF/update-key-backup.txt"
if [[ $CHECK -eq 0 ]]; then
  read_key "$KC" > "$BACKUP"
  chmod 600 "$BACKUP"
elif [[ ! -f "$BACKUP" ]]; then
  BACKUP="$TMP/update-key-backup.txt"
  read_key "$KC" > "$BACKUP"
fi
SCRATCH_PW="$(openssl rand -hex 16)"
security create-keychain -p "$SCRATCH_PW" "$SCRATCH_KC"
store_key "$SCRATCH_KC" < "$BACKUP"
restore_list
RESTORED_PUBLIC="$(read_key "$SCRATCH_KC" | "$ED" public)" || die "couldn't read the key back from the scratch keychain"
echo "Tether update key restore check $(date -u +%FT%TZ)" > "$TMP/test.txt"
SIG="$(read_key "$SCRATCH_KC" | "$SIGN_UPDATE" --ed-key-file - -p "$TMP/test.txt")" || die "sign_update couldn't sign with the restored key"
if [[ "$RESTORED_PUBLIC" != "$PUBLIC" ]]; then
  die "the backup export does not match the update key (public keys differ): don't use this backup"
fi
"$ED" verify "$PUBLIC" "$SIG" "$TMP/test.txt" || die "a test file signed with the restored key doesn't verify against the update key"
echo "✓ backup export checked: restored into a scratch keychain, it signs a test file the update key accepts"

# --- The release signing identity: made once.
if [[ -f "$CONF/release-cert.pem" ]]; then
  echo "✓ the release signing identity already exists (kept as it is)"
else
  missing "no release signing identity ($CONF/release-cert.pem)"
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
  "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days "$CERT_DAYS" -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
  P12PW="$(openssl rand -hex 16)"
  # 3DES and SHA-1: the p12 format both macOS's security import and LibreSSL/OpenSSL 3 read.
  "$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" \
    -passout "pass:$P12PW" -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
  # The secret: the p12's password on the first line, the p12 in base64 on the second.
  { printf '%s\n' "$P12PW"; base64 -i "$TMP/id.p12" | tr -d '\n'; printf '\n'; } > "$CONF/github-secret.txt"
  chmod 600 "$CONF/github-secret.txt"
  # Kept in the release keychain too, as setup-signing.sh keeps its own, so the secret can be remade.
  security import "$TMP/id.p12" -k "$KC" -P "$P12PW" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(cat "$PWFILE")" "$KC" >/dev/null
  restore_list
  cp "$TMP/cert.pem" "$CONF/release-cert.pem"; chmod 644 "$CONF/release-cert.pem"
  echo "✓ made the release signing identity \"$NAME\""
fi
# The fingerprint codesign reports for the leaf certificate (SHA-256 of its DER form).
"$OPENSSL" x509 -in "$CONF/release-cert.pem" -outform DER | shasum -a 256 | awk '{print $1}' > "$CONF/release-cert.sha256"
chmod 644 "$CONF/release-cert.sha256"
security find-certificate -c "$NAME" -Z "$KC" 2>/dev/null | grep -qi "SHA-256 hash: $(cat "$CONF/release-cert.sha256")" \
  || die "the release keychain doesn't hold the \"$NAME\" certificate whose fingerprint is in $CONF/release-cert.sha256"
security find-identity -p codesigning "$KC" | grep -q "\"$NAME\"" || die "the release keychain has no \"$NAME\" signing identity"
echo "✓ the release signing identity \"$NAME\" is in $KC"
if [[ $CHECK -eq 1 ]]; then
  echo "✓ check passed. Update key (public): $PUBLIC  Signing certificate SHA-256: $(cat "$CONF/release-cert.sha256")"
  exit 0
fi

cat <<DONE

Update key (public half, goes into every release build):
  $PUBLIC
Release signing certificate SHA-256:
  $(cat "$CONF/release-cert.sha256")

What only you do (G-1):
  1. Store the signing identity in GitHub. Run this one command on this Mac:
       gh secret set $SECRET_NAME -R $REPO < "$CONF/github-secret.txt"
     (If gh says you are not signed in, run gh auth login first.)
     Then you may delete $CONF/github-secret.txt.
  2. Back up the update key: open $CONF/update-key-backup.txt, save its one line in your password
     manager as "Tether update key", then delete the file.
DONE
