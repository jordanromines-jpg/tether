#!/usr/bin/env bash
# Tether end-to-end setup. Safe to run again at any time: finished steps are skipped.
#
#   scripts/setup.sh                          # make THIS Mac controllable
#   scripts/setup.sh --remote user@other-mac  # make ANOTHER Mac on your tailnet controllable (via SSH)
#   scripts/setup.sh --check [--remote ...]   # read-only: report what's done and what's left
#   options for --remote:  --key ~/.ssh/some_key  (an SSH key you already use for that Mac)
#                          --name studio          (short name to save it under for scripts/deploy.sh)
#   shortcut:  --shortcut-dir <folder>  where to put the "Tether" shortcut (default: /Applications)
#              --no-shortcut            don't make one
#
# Exit codes: 0 done · 3 ACTION NEEDED (a step for the person at the Mac; run again after) · 1 error
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/common.sh"
# Any unexpected failure still ends with a readable ✗ line and exit code 1.
trap 'rc=$?; printf "\n  ✗ Setup stopped unexpectedly at line %s (%s, exit %s).\n    Run it again; if it repeats, share this output.\n" "$LINENO" "$BASH_COMMAND" "$rc" >&2; exit 1' ERR

CHECK=0; REMOTE=""; NAME=""; KEY_ARG=""; SHORTCUT_DIR="/Applications"; NO_SHORTCUT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK=1 ;;
    --remote) REMOTE="${2:?--remote needs user@machine}"; shift ;;
    --name) NAME="${2:?}"; shift ;;
    --key) KEY_ARG="${2:?--key needs a path}"; shift ;;
    --shortcut-dir) SHORTCUT_DIR="${2:?--shortcut-dir needs a folder}"; shift ;;
    --no-shortcut) SHORTCUT_DIR="" ; NO_SHORTCUT=1 ;;
    -h|--help) sed -n 2,13p "$0"; exit 0 ;;
    *) fail "unknown option $1" ;;
  esac
  shift
done
check_only() { [[ $CHECK == 1 ]]; }

echo "Tether setup — $([[ -n "$REMOTE" ]] && echo "controlling $REMOTE from this Mac" || echo "making this Mac controllable")$(check_only && echo " (check only)" || true)"

# 1 ── This Mac: macOS version ─────────────────────────────────────────────
step "Checking macOS"
MACOS="$(sw_vers -productVersion)"
[[ "${MACOS%%.*}" -ge 14 ]] || fail "Tether needs macOS 14 (Sonoma) or newer; this Mac has $MACOS."
ok "macOS $MACOS on $(uname -m)"

# 2 ── Developer tools (to build the app from source) ──────────────────────
step "Checking Apple's Command Line Tools"
if ! xcode-select -p >/dev/null 2>&1; then
  if check_only; then
    info "missing — the remaining checks need them, so the check stops here. Nothing was changed."; exit 0
  fi
  xcode-select --install >/dev/null 2>&1 || true
  action_needed "A window titled \"Install Command Line Developer Tools\" should have opened." \
    "Click Install, agree to the license, and wait for it to finish (about 5–15 minutes)." \
    "If no window appeared, open Terminal and run:  xcode-select --install"
elif ! swift --version >/dev/null 2>&1; then
  # Tools are present but unusable — almost always Xcode's license not yet accepted.
  check_only && { info "installed but not usable yet (Xcode license not accepted?)"; exit 0; }
  action_needed "Apple's developer tools are installed but need their license accepted." \
    "Open Terminal and run this (it asks for this Mac's login password; type it — nothing shows while typing):" \
    "    sudo xcodebuild -license accept"
else
  ok "installed ($(swift --version 2>&1 | head -1 | sed -E 's/.*(Swift version [0-9.]+).*/\1/'))"
fi

# 3 ── Tailscale on this Mac ────────────────────────────────────────────────
step "Checking Tailscale"
TS="$(tailscale_cli)"
LOGIN=""
if [[ -z "$TS" ]]; then
  check_only && info "not installed" || action_needed \
    "Install Tailscale on this Mac: open https://tailscale.com/download/mac and install it." \
    "Open Tailscale from Applications and sign in (create a free account if you don't have one)."
elif [[ "$(tailscale_json 'd["BackendState"]' || true)" != "Running" ]]; then
  check_only && info "installed but not signed in / not connected" || action_needed \
    "Open the Tailscale app (menu bar icon) and sign in, then make sure it says Connected."
else
  LOGIN="$(tailscale_login || true)"
  [[ -n "$LOGIN" ]] || fail "Tailscale is connected but this Mac isn't signed in as a person (is it a tagged device?). Sign in to Tailscale with your own account."
  ok "connected as $LOGIN"
fi
ALLOWED_LOGINS="${ALLOWED_LOGINS:-$LOGIN}"

# Helper: run a command on the target Mac (this Mac, or the remote one over SSH)
KEY="${KEY_ARG:-$HOME/.ssh/tether_ed25519}"; KEY="${KEY/#\~/$HOME}"
SSH_OPTS=(-o ConnectTimeout=8 -o BatchMode=yes)
on_target() { if [[ -n "$REMOTE" ]]; then ssh "${SSH_OPTS[@]}" "$REMOTE" "$@"; else bash -c "$*"; fi; }
REMOTE_TS='(/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json 2>/dev/null || tailscale status --json 2>/dev/null || /opt/homebrew/bin/tailscale status --json)'
TARGET_NAME="$([[ -n "$REMOTE" ]] && echo "the other Mac (${REMOTE#*@})" || echo "this Mac")"

# 4 ── Remote only: SSH access to the other Mac ─────────────────────────────
if [[ -n "$REMOTE" ]]; then
  step "Checking SSH access to $REMOTE"
  [[ -f "$KEY" ]] && SSH_OPTS+=(-i "$KEY" -o IdentitiesOnly=yes)
  if ssh "${SSH_OPTS[@]}" -o StrictHostKeyChecking=accept-new "$REMOTE" true 2>/dev/null; then
    ok "can sign in to $REMOTE"
  else
    if check_only; then
      info "can't sign in yet (Remote Login off, or no SSH key set up)"
      echo; echo "Check stopped here: the remaining steps need SSH access to $REMOTE. Nothing was changed."; exit 0
    fi
    [[ -f "$KEY" ]] || ssh-keygen -q -t ed25519 -N "" -C "tether@$(scutil --get LocalHostName)" -f "$KEY"
    action_needed \
      "1. On the OTHER Mac: System Settings → General → Sharing → turn on \"Remote Login\"." \
      "2. On THIS Mac, open Terminal and run:" \
      "       ssh-copy-id -i \"$KEY.pub\" $REMOTE" \
      "   If it asks \"Are you sure you want to continue connecting (yes/no)?\", type yes and press Return." \
      "   Then type the OTHER Mac's login password (nothing shows while you type) and press Return."
  fi
  RARCH="$(on_target uname -m)" || fail "Lost the SSH connection to $REMOTE. Check it's awake and on Tailscale, then run again."
  RMAC="$(on_target sw_vers -productVersion)" || fail "Lost the SSH connection to $REMOTE."
  [[ "${RMAC%%.*}" -ge 14 ]] || fail "The other Mac has macOS $RMAC; Tether needs 14 or newer."
  [[ "$RARCH" == "$(uname -m)" ]] || fail "The other Mac is $RARCH but this Mac is $(uname -m), so an app built here won't run there. Run this setup directly on the other Mac instead."
  ok "other Mac: macOS $RMAC on $RARCH"
  step "Checking Tailscale on $REMOTE"
  RSTATE="$(on_target "$REMOTE_TS" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null || true)"
  if [[ "$RSTATE" == Running ]]; then
    ok "connected"
  else
    check_only && info "not running or not signed in" || action_needed \
      "On the OTHER Mac: make sure Tailscale is installed (https://tailscale.com/download/mac), open," \
      "and signed in with the SAME account as this Mac ($LOGIN) — its menu-bar icon should say Connected."
  fi
fi

# 5 ── HTTPS certificates for the tailnet ───────────────────────────────────
step "Checking Tailscale HTTPS certificates"
CERTS="$(on_target "$REMOTE_TS" 2>/dev/null | python3 -c 'import json,sys;print("yes" if json.load(sys.stdin).get("CertDomains") else "no")' 2>/dev/null || echo no)"
if [[ "$CERTS" == yes ]]; then
  ok "enabled"
else
  check_only && info "not enabled" || action_needed \
    "Turn on HTTPS for your Tailscale network (Tether's video needs it):" \
    "  1. Open https://login.tailscale.com/admin/dns" \
    "  2. Under \"HTTPS Certificates\", click Enable HTTPS… then Enable." \
    "Note: Tailscale records your machine names (e.g. my-mac.tailXXXX.ts.net) in a public certificate log." \
    "Nobody can reach them — the link only works inside your tailnet — but the names are visible."
fi

if check_only; then
  step "Checking Tether itself"
  if on_target "test -x ~/Applications/Tether.app/Contents/MacOS/Tether" 2>/dev/null; then ok "installed"; else info "not installed yet"; fi
  echo; echo "Check complete (nothing was changed)."; exit 0
fi

# 6 ── Signing identity (keeps macOS permissions across updates) ────────────
step "Preparing a signing identity"
"$ROOT/scripts/setup-signing.sh" | sed 's/^/  /'

# 7 ── Build (skipped when nothing changed since the last successful build) ─
APP="$ROOT/build/Tether.app"
STAMP_FILE="$ROOT/build/.source-stamp"
STAMP="$( (git -C "$ROOT" rev-parse HEAD 2>/dev/null; git -C "$ROOT" status --porcelain 2>/dev/null) | shasum | cut -c1-16)"
if [[ -x "$APP/Contents/MacOS/Tether" && -f "$STAMP_FILE" && "$(cat "$STAMP_FILE")" == "$STAMP" ]] && git -C "$ROOT" rev-parse HEAD >/dev/null 2>&1; then
  step "Building Tether"
  ok "already built from this version"
else
  step "Building Tether (the first build downloads components and can take 10–20 minutes)"
  LOG="$ROOT/build/build.log"; mkdir -p "$ROOT/build"
  # Show progress about once a minute so a long first build doesn't look stuck.
  set +e
  "$ROOT/scripts/build-app.sh" >"$LOG" 2>&1 &
  BUILD_PID=$!
  SECS=0
  while kill -0 "$BUILD_PID" 2>/dev/null; do
    sleep 5; SECS=$((SECS + 5))
    (( SECS % 60 == 0 )) && info "still building… ($((SECS / 60)) min) $(grep -oE '^\[[0-9]+/[0-9]+\]' "$LOG" | tail -1)"
  done
  wait "$BUILD_PID"; BUILD_RC=$?
  set -e
  if [[ $BUILD_RC -ne 0 || ! -x "$APP/Contents/MacOS/Tether" ]]; then
    echo "  Last lines of the build log ($LOG):" >&2
    grep -E 'error:|warning: unable|fatal' "$LOG" | tail -5 | sed 's/^/    /' >&2 || tail -8 "$LOG" | sed 's/^/    /' >&2
    fail "The build failed. Full log: $LOG"
  fi
  echo "$STAMP" > "$STAMP_FILE"
  grep -E '^(›|✓|!)' "$LOG" | sed 's/^/  /' || true
  ok "built"
fi

# 8 ── Install + publish ─────────────────────────────────────────────────────
step "Installing Tether on $TARGET_NAME"
if [[ -n "$REMOTE" ]]; then
  on_target 'mkdir -p ~/Applications' || fail "Lost the SSH connection to $REMOTE."
  rsync -a --delete -e "$(printf '%q ' ssh "${SSH_OPTS[@]}")" "$APP/" "$REMOTE:Applications/Tether.app/" \
    || fail "Couldn't copy Tether to $REMOTE. Check the connection and run again."
  OUT="$(ssh "${SSH_OPTS[@]}" "$REMOTE" bash -s -- "$ALLOWED_LOGINS" "$TETHER_PORT" < "$ROOT/scripts/lib/install-agent.sh" 2>&1)" \
    || { printf '%s\n' "$OUT" | sed 's/^/  /' >&2; fail "Installing on $REMOTE failed (see above)."; }
  # Remember this Mac for future updates: scripts/deploy.sh <name>
  HOSTPART="${REMOTE#*@}"
  NAME="${NAME:-$(echo "${HOSTPART%%.*}" | tr -cd 'A-Za-z0-9-')}"
  mkdir -p "$HOME/.config/tether/targets"
  { echo "HOST=$REMOTE"; [[ -f "$KEY" ]] && echo "SSH_KEY=$KEY"; echo "ALLOWED_LOGINS=$ALLOWED_LOGINS"; } > "$HOME/.config/tether/targets/$NAME.env"
  info "saved as \"$NAME\" — update it later with: scripts/deploy.sh $NAME"
else
  mkdir -p "$HOME/Applications"
  rsync -a --delete "$APP/" "$HOME/Applications/Tether.app/"
  OUT="$(bash "$ROOT/scripts/lib/install-agent.sh" "$ALLOWED_LOGINS" "$TETHER_PORT" 2>&1)" \
    || { printf '%s\n' "$OUT" | sed 's/^/  /' >&2; fail "Installing Tether failed (see above)."; }
fi
printf '%s\n' "$OUT" | grep -v '^TETHER_RESULT' || true
RESULT="$(printf '%s\n' "$OUT" | grep '^TETHER_RESULT' | tail -1 || true)"
field() { sed -nE "s/.*$1=([^ ]+).*/\1/p" <<<"$RESULT"; }
URL="$(field url)"; SCREEN="$(field screen)"; INPUT="$(field input)"

# 9 ── macOS permissions (only the person at the Mac can grant these) ───────
step "Checking macOS permissions on $TARGET_NAME"
if [[ "$SCREEN" == unknown || -z "$SCREEN" ]]; then
  fail "Tether was installed but isn't answering on $TARGET_NAME. Its log is ~/Library/Logs/Tether.log there (look for errors such as \"address already in use\")."
elif [[ "$SCREEN" == true && "$INPUT" == true ]]; then
  ok "Screen Recording and Accessibility are allowed"
else
  MISSING=()
  [[ "$SCREEN" == true ]] || MISSING+=("Screen Recording")
  [[ "$INPUT" == true ]] || MISSING+=("Accessibility")
  # The Setup Assistant (in the app) walks through this with live checkmarks.
  if [[ -z "$REMOTE" ]]; then
    open "tether://setup" 2>/dev/null || open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" || true
    WHERE="On this Mac, the Tether Setup Assistant just opened. Follow its Permissions step"
  else
    on_target 'open "tether://setup"' >/dev/null 2>&1 || true
    WHERE="On the OTHER Mac (${REMOTE#*@}), the Tether Setup Assistant just opened. Someone there (or you, through Screen Sharing) follows its Permissions step"
  fi
  BULLETS=(); for m in "${MISSING[@]}"; do BULLETS+=("  • $m"); done
  action_needed "$WHERE. It turns on \"Tether\" in System Settings → Privacy & Security under:" \
    "${BULLETS[@]}" \
    "Its checkmarks turn green by themselves. If the window isn't showing, click the Tether icon in the" \
    "menu bar and choose Setup Assistant. If Tether isn't in a list: click +, press ⌘⇧H for the home folder," \
    "open Applications there (not the main Applications folder) and choose Tether. If it was allowed before" \
    "an update, select it, click −, then add it again."
fi

# 10 ── Shortcut ─────────────────────────────────────────────────────────────
if [[ $NO_SHORTCUT == 0 ]]; then
  step "Adding a Tether shortcut to $SHORTCUT_DIR on $TARGET_NAME"
  ALIAS_CMD="\"\$HOME/Applications/Tether.app/Contents/MacOS/Tether\" --make-alias $(printf '%q' "$SHORTCUT_DIR")"
  if ALIAS_OUT="$(on_target "$ALIAS_CMD" 2>&1)"; then
    ok "shortcut at $ALIAS_OUT (open it to start Tether again after quitting)"
  else
    info "Skipped: $ALIAS_OUT"
    info "Make one later from the Tether menu-bar icon → Add a shortcut, or: scripts/shortcut.sh app <folder>"
  fi
fi

# 11 ── Done ───────────────────────────────────────────────────────────────
step "Tips"
SLEEP="$(on_target "pmset -g | awk '/^ sleep / {print \$2}'" 2>/dev/null || echo "")"
if [[ -n "$SLEEP" && "$SLEEP" != 0 ]]; then
  info "$([[ -n "$REMOTE" ]] && echo "The other Mac" || echo "This Mac") goes to sleep after $SLEEP min of inactivity, and a sleeping Mac can't be reached. For always-on access:"
  info "on that Mac, System Settings → Energy (or Battery → Options) → turn on \"Prevent automatic sleeping when the display is off\"."
fi
cat <<DONE

✓ Tether is ready.

  Open this link on your iPhone, iPad, or another computer:
      $URL

  On each device: install Tailscale, sign in with the SAME account ($LOGIN),
  then open the link. On iPhone/iPad, tap Share → Add to Home Screen.
  Tip: the Tether menu-bar icon on the Mac has "Show QR code" so you can just scan it.

  Controlling it from another Mac? On that Mac, in this folder, run:
      scripts/shortcut.sh viewer ${URL}
  to get a "Tether" app that opens the screen in its own window.
DONE
