#!/usr/bin/env bash
# Removes Tether.
#
#   scripts/uninstall.sh                 # from THIS Mac
#   scripts/uninstall.sh <target>        # from another Mac set up with setup.sh --remote
#                                        # (target names live in ~/.config/tether/targets/)
#   add --all to also delete Tether's settings, passkeys and logs
#   (on this Mac, --all also removes the signing keychain and saved targets used for building)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET=""; ALL=""
for a in "$@"; do case "$a" in --all) ALL="--all" ;; -h|--help) sed -n 2,9p "$0"; exit 0 ;; *) TARGET="$a" ;; esac; done

if [[ -n "$TARGET" ]]; then
  TARGET_FILE="$HOME/.config/tether/targets/$TARGET.env"
  [[ -f "$TARGET_FILE" ]] || { echo "  ✗ No saved target \"$TARGET\" (looked for $TARGET_FILE)." >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$TARGET_FILE"
  KEY="${SSH_KEY:-}"; KEY="${KEY/#\~/$HOME}"
  SSH_OPTS=(-o ConnectTimeout=8 -o BatchMode=yes)
  [[ -n "$KEY" && -f "$KEY" ]] && SSH_OPTS+=(-i "$KEY" -o IdentitiesOnly=yes)
  echo "Removing Tether from $HOST"
  ssh "${SSH_OPTS[@]}" "$HOST" bash -s -- "$ALL" < "$ROOT/scripts/lib/uninstall-agent.sh"
  if [[ "$ALL" == "--all" ]]; then rm -f "$TARGET_FILE" && echo "  ✓ forgot saved target \"$TARGET\""; fi
else
  echo "Removing Tether from this Mac"
  bash "$ROOT/scripts/lib/uninstall-agent.sh" "$ALL"
  if [[ "$ALL" == "--all" ]]; then
    KC="$HOME/Library/Keychains/tether-signing.keychain-db"
    if [[ -f "$KC" ]]; then security delete-keychain "$KC" && echo "  ✓ removed the Tether signing keychain"; fi
    [[ -d "$HOME/.config/tether" ]] && rm -rf "$HOME/.config/tether" && echo "  ✓ removed ~/.config/tether"
  fi
fi
echo "✓ Done."
