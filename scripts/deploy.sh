#!/usr/bin/env bash
# Updates Tether on another Mac you've already set up (see scripts/setup.sh --remote).
#
#   scripts/deploy.sh <target>                 # build here, copy it over, reinstall
#   scripts/deploy.sh <target> --self-update   # from now on, that Mac updates itself ("Update now" in its panel)
#
# --self-update needs Apple's developer tools on that Mac. It puts a copy of the Tether source in
# ~/Library/Application Support/Tether/source there and copies this Mac's Tether signing keychain,
# so its own builds keep the same identity and its Screen Recording and Accessibility permissions.
# After that, `scripts/deploy.sh <target>` (and `scripts/update.sh --all`) just ask it to update.
#
# <target> is a private file ~/.config/tether/targets/<target>.env (never committed):
#   HOST=user@my-mac                 # SSH destination (Tailscale machine name works from anywhere)
#   SSH_KEY=~/.ssh/tether_ed25519    # optional
#   ALLOWED_LOGINS=me@example.com    # optional; defaults to your own Tailscale login
#   SELF_UPDATE=1                    # set by --self-update
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/common.sh"
TARGET="${1:-}"; MODE="${2:-}"
TARGET_FILE="$HOME/.config/tether/targets/$TARGET.env"
if [[ -z "$TARGET" || ! -f "$TARGET_FILE" || ( -n "$MODE" && "$MODE" != --self-update ) ]]; then
  echo "usage: scripts/deploy.sh <target> [--self-update]   (reads ~/.config/tether/targets/<target>.env)" >&2
  ls "$HOME/.config/tether/targets" 2>/dev/null | sed 's/\.env$//; s/^/  available: /' >&2 || true
  exit 2
fi
SELF_UPDATE=""
# shellcheck disable=SC1090
source "$TARGET_FILE"
HOST="${HOST:?HOST missing in $TARGET_FILE}"
KEY="${SSH_KEY:-}"; KEY="${KEY/#\~/$HOME}"
# Builds take minutes: keep the connection alive while the other Mac works.
SSH_OPTS=(-o ConnectTimeout=8 -o BatchMode=yes -o ServerAliveInterval=30)
[[ -n "$KEY" && -f "$KEY" ]] && SSH_OPTS+=(-i "$KEY" -o IdentitiesOnly=yes)
remote() { ssh "${SSH_OPTS[@]}" "$HOST" "$@"; }
SRC='$HOME/Library/Application Support/Tether/source'

echo "› checking $HOST"
remote true || fail "Can't reach $HOST over SSH. Check it's awake and on Tailscale."

# ── A self-updating Mac: ask it to update itself ───────────────────────────────
if [[ "$SELF_UPDATE" == 1 && -z "$MODE" ]]; then
  echo "› $TARGET updates itself; asking it to update"
  remote "bash \"$SRC/scripts/update.sh\"" || fail "The update on $TARGET stopped (see above)."
  exit 0
fi

# ── Make it self-updating ──────────────────────────────────────────────────────
if [[ "$MODE" == --self-update ]]; then
  echo "› checking Apple's developer tools on $TARGET"
  remote 'xcode-select -p >/dev/null && swift --version >/dev/null 2>&1 && git --version >/dev/null' \
    || fail "$TARGET needs Apple's Command Line Tools (and their license accepted) to build Tether. Run scripts/setup.sh on it once, or keep updating it from here."
  KC="$HOME/Library/Keychains/tether-signing.keychain-db"
  PWFILE="$HOME/.config/tether/signing-keychain-password"
  [[ -f "$KC" && -f "$PWFILE" ]] || fail "This Mac has no Tether signing identity to share. Run scripts/setup-signing.sh first."
  # Copying the identity keeps that Mac's permissions; replacing a DIFFERENT identity would reset them.
  MINE="$(security find-certificate -c "Tether Signing" -Z "$KC" | awk '/SHA-1/ {print $3; exit}')"
  THEIRS="$(remote 'f="$HOME/Library/Keychains/tether-signing.keychain-db"; [[ -f "$f" ]] && security find-certificate -c "Tether Signing" -Z "$f" | awk "/SHA-1/ {print \$3; exit}"' || true)"
  if [[ -n "$THEIRS" && "$THEIRS" != "$MINE" ]]; then
    fail "$TARGET already has a different Tether signing identity. Copying this one would reset its permissions, so nothing was changed."
  fi
  if [[ -z "$THEIRS" ]]; then
    echo "› copying the Tether signing identity"
    remote 'mkdir -p ~/.config/tether ~/Library/Keychains && chmod 700 ~/.config/tether'
    scp -q "${SSH_OPTS[@]}" "$KC" "$HOST:Library/Keychains/tether-signing.keychain-db"
    scp -q "${SSH_OPTS[@]}" "$PWFILE" "$HOST:.config/tether/signing-keychain-password"
    remote "chmod 600 ~/Library/Keychains/tether-signing.keychain-db ~/.config/tether/signing-keychain-password && \
      echo $(printf '%q' "$(scutil --get ComputerName)") > ~/.config/tether/signing-copied-from"
  fi
  REPO_URL="$(git -C "$ROOT" config --get remote.origin.url)"
  REPO="$(sed -E 's#\.git$##; s#^.*github\.com[:/]##' <<<"$REPO_URL")"
  [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || fail "This checkout's origin ($REPO_URL) isn't a GitHub repo."
  echo "› getting the Tether source on $TARGET (github.com/$REPO)"
  remote "if [[ -d \"$SRC/.git\" ]]; then echo '  already there'; else git clone --quiet --branch main https://github.com/$REPO.git \"$SRC\"; fi" \
    || fail "Couldn't download the source on $TARGET."
  echo "› building and installing on $TARGET (a few minutes the first time)"
  remote "bash \"$SRC/scripts/update.sh\"" || fail "The first build on $TARGET stopped (see above). Nothing else was changed."
  grep -q '^SELF_UPDATE=' "$TARGET_FILE" && sed -i '' 's/^SELF_UPDATE=.*/SELF_UPDATE=1/' "$TARGET_FILE" || echo "SELF_UPDATE=1" >> "$TARGET_FILE"
  ok "$TARGET now updates itself: \"Update now\" in its Tether panel, or scripts/deploy.sh $TARGET from here"
  exit 0
fi

# ── Build here and install there ───────────────────────────────────────────────
ALLOWED_LOGINS="${ALLOWED_LOGINS:-$(tailscale_login)}"
echo "› allowed Tailscale logins: $ALLOWED_LOGINS"
"$ROOT/scripts/build-app.sh"
echo "› copying app"
remote 'mkdir -p ~/Applications'
rsync -a --delete -e "$(printf '%q ' ssh "${SSH_OPTS[@]}")" "$ROOT/build/Tether.app/" "$HOST:Applications/Tether.app/"
echo "› installing"
# Updates for that Mac come from this one (its update banner names this Mac).
ssh "${SSH_OPTS[@]}" "$HOST" bash -s -- "$ALLOWED_LOGINS" "$TETHER_PORT" "''" "$(printf '%q' "$(scutil --get ComputerName)")" \
  < "$ROOT/scripts/lib/install-agent.sh"
