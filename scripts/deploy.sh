#!/usr/bin/env bash
# Updates Tether on another Mac you've already set up (see scripts/setup.sh --remote).
#
#   scripts/deploy.sh <target>
#
# <target> is a private file ~/.config/tether/targets/<target>.env (never committed):
#   HOST=user@my-mac                 # SSH destination (Tailscale machine name works from anywhere)
#   SSH_KEY=~/.ssh/tether_ed25519    # optional
#   ALLOWED_LOGINS=me@example.com    # optional; defaults to your own Tailscale login
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/common.sh"
TARGET="${1:-}"
TARGET_FILE="$HOME/.config/tether/targets/$TARGET.env"
if [[ -z "$TARGET" || ! -f "$TARGET_FILE" ]]; then
  echo "usage: scripts/deploy.sh <target>   (reads ~/.config/tether/targets/<target>.env)" >&2
  ls "$HOME/.config/tether/targets" 2>/dev/null | sed 's/\.env$//; s/^/  available: /' >&2 || true
  exit 2
fi
# shellcheck disable=SC1090
source "$TARGET_FILE"
HOST="${HOST:?HOST missing in $TARGET_FILE}"
KEY="${SSH_KEY:-}"; KEY="${KEY/#\~/$HOME}"
SSH_OPTS=(-o ConnectTimeout=8 -o BatchMode=yes)
[[ -n "$KEY" && -f "$KEY" ]] && SSH_OPTS+=(-i "$KEY" -o IdentitiesOnly=yes)
ALLOWED_LOGINS="${ALLOWED_LOGINS:-$(tailscale_login)}"
echo "› allowed Tailscale logins: $ALLOWED_LOGINS"

"$ROOT/scripts/build-app.sh"

echo "› checking $HOST"
ssh "${SSH_OPTS[@]}" "$HOST" true
echo "› copying app"
ssh "${SSH_OPTS[@]}" "$HOST" 'mkdir -p ~/Applications'
rsync -a --delete -e "$(printf '%q ' ssh "${SSH_OPTS[@]}")" "$ROOT/build/Tether.app/" "$HOST:Applications/Tether.app/"
echo "› installing"
ssh "${SSH_OPTS[@]}" "$HOST" bash -s -- "$ALLOWED_LOGINS" "$TETHER_PORT" < "$ROOT/scripts/lib/install-agent.sh"
