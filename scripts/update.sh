#!/usr/bin/env bash
# Updates Tether from GitHub and reinstalls it. The new copy is signed with the same identity,
# so Screen Recording and Accessibility stay allowed. Safe to run again at any time.
#
#   scripts/update.sh                       # this Mac (Tether's "Update now" runs this)
#   scripts/update.sh --all                 # this Mac, then every Mac saved in ~/.config/tether/targets
#   options:  --status-file <path>          # progress as JSON, read by Tether's menu-bar panel
#
# Only ever fast-forwards main from the repo Tether was built from. A copy with changes of its own
# is left alone (update it in Terminal). Exit codes: 0 done or already up to date · 1 problem.
# TETHER_UPDATE_DRY_RUN=1 skips the build and install (used by scripts/tests/update.test.sh).
set -euo pipefail

# bash reads a script while it runs it, and the pull below may replace this file: run a copy.
if [[ -z "${TETHER_UPDATE_COPY:-}" ]]; then
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  COPY="$(mktemp -t tether-update)"
  cp "$0" "$COPY"
  TETHER_UPDATE_COPY="$COPY" TETHER_UPDATE_ROOT="$ROOT" exec bash "$COPY" "$@"
fi
ROOT="$TETHER_UPDATE_ROOT"
source "$ROOT/scripts/lib/common.sh"

ALL=0; STATUS_FILE=""; AFTER_PULL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) ALL=1 ;;
    --status-file) STATUS_FILE="${2:?--status-file needs a path}"; shift ;;
    --after-pull) AFTER_PULL=1 ;;
    -h|--help) sed -n 2,11p "$ROOT/scripts/update.sh"; exit 0 ;;
    *) fail "unknown option $1" ;;
  esac
  shift
done
ARGS=(); [[ $ALL == 1 ]] && ARGS+=(--all); [[ -n "$STATUS_FILE" ]] && ARGS+=(--status-file "$STATUS_FILE")
DRY="${TETHER_UPDATE_DRY_RUN:-}"

SUPPORT="$HOME/Library/Application Support/Tether"
CONFIG="$SUPPORT/config.json"
INSTALLED="$HOME/Applications/Tether.app"
FROM="${TETHER_UPDATE_FROM:-}"; TO=""; STEP="checking"

# Progress for the menu-bar panel: one small JSON object, replaced atomically.
status() {   # state message
  [[ -n "$STATUS_FILE" ]] || return 0
  local msg; msg="$(printf '%s' "$2" | tr -d '"\\' | tr '\n' ' ')"
  printf '{"state":"%s","step":"%s","message":"%s","from":"%s","to":"%s","at":"%s"}\n' \
    "$1" "$STEP" "$msg" "$FROM" "$TO" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATUS_FILE.tmp"
  mv "$STATUS_FILE.tmp" "$STATUS_FILE"
}
DIED=0
die() { DIED=1; status failed "$1"; fail "$1"; }
# Anything unexpected still leaves a readable status (die has already written a better one).
on_exit() {
  local rc=$?
  if [[ $rc -ne 0 && $DIED == 0 ]]; then status failed "The update stopped unexpectedly. See ~/Library/Logs/Tether-update.log."; fi
  rm -f "$TETHER_UPDATE_COPY"
}
trap on_exit EXIT
plist() { plutil -extract "$1" raw -o - "$2" 2>/dev/null || true; }
git_() { git -C "$ROOT" "$@"; }

# Is Tether installed on this Mac from this checkout? (An install managed from another Mac has no
# sourceDir; running this script there takes it over, which is how a Mac becomes self-updating.)
LOCAL=0
if [[ -x "$INSTALLED/Contents/MacOS/Tether" && -f "$CONFIG" ]]; then
  SRC="$(plist sourceDir "$CONFIG")"
  [[ -z "$SRC" || "$SRC" == "$ROOT" ]] && LOCAL=1
fi

if [[ $AFTER_PULL == 0 ]]; then
  echo "Tether update"
  step "Checking this copy of Tether"
  status running "Checking"
  git_ rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$ROOT isn't a git checkout, so it can't update itself."
  BRANCH="$(git_ symbolic-ref --short -q HEAD || true)"
  [[ "$BRANCH" == main ]] || die "This copy is on \"${BRANCH:-a detached commit}\", not main. Update it in Terminal."
  # Only the repo Tether was built from (forks update from themselves).
  EXPECT=""
  if [[ $LOCAL == 1 ]]; then EXPECT="$(plist TetherRepo "$INSTALLED/Contents/Info.plist")"; fi
  ORIGIN="$(git_ config --get remote.origin.url || true)"
  ORIGIN_REPO="$(sed -E 's#\.git$##; s#^.*github\.com[:/]##' <<<"$ORIGIN")"
  [[ -n "$EXPECT" ]] || EXPECT="$ORIGIN_REPO"
  [[ "$ORIGIN_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "$ORIGIN_REPO" == "$EXPECT" ]] \
    || die "This copy pulls from \"$ORIGIN\", but Tether was built from github.com/$EXPECT. Update it in Terminal."
  [[ -z "$(git_ status --porcelain --untracked-files=no)" ]] \
    || die "This copy has changes of its own that aren't committed. Update it in Terminal."
  ok "on main, from github.com/$EXPECT, no local changes"

  step "Getting the latest version"
  STEP="downloading"; status running "Downloading the latest version"
  git_ fetch --quiet origin main 2>/dev/null || die "Couldn't reach GitHub. Check the internet connection and try again."
  FROM="$(git_ rev-parse HEAD)"; TO="$(git_ rev-parse origin/main)"
  if [[ "$FROM" != "$TO" ]]; then
    git_ merge-base --is-ancestor HEAD origin/main \
      || die "This copy has commits of its own that aren't on GitHub. Update it in Terminal."
    git_ merge --ff-only --quiet origin/main || die "Couldn't move to the latest version. Update it in Terminal."
    ok "$(git_ rev-list --count "$FROM..$TO") new change(s): ${FROM:0:7} → ${TO:0:7}"
    # Carry on with the NEW script, so new build and install steps are used.
    rm -f "$TETHER_UPDATE_COPY"
    TETHER_UPDATE_COPY="" TETHER_UPDATE_FROM="$FROM" exec bash "$ROOT/scripts/update.sh" --after-pull ${ARGS[@]+"${ARGS[@]}"}
  fi
  ok "already at the latest version (${TO:0:7})"
fi
FROM="${FROM:-$(git_ rev-parse HEAD)}"; TO="$(git_ rev-parse HEAD)"

# ── This Mac ──────────────────────────────────────────────────────────────────
if [[ $LOCAL == 1 ]]; then
  if [[ "$(plist TetherCommit "$INSTALLED/Contents/Info.plist")" == "$TO" && $AFTER_PULL == 0 ]]; then
    step "Tether on this Mac"
    ok "already up to date"
    status current "Already up to date"
  else
    step "Building Tether (usually a few minutes)"
    STEP="building"; status running "Building (usually a few minutes)"
    LOG="$ROOT/build/build.log"; mkdir -p "$ROOT/build"
    if [[ -n "$DRY" ]]; then
      echo "dry run: build-app.sh" > "$LOG"
    else
      set +e
      "$ROOT/scripts/build-app.sh" >"$LOG" 2>&1 &
      BUILD_PID=$!; SECS=0
      while kill -0 "$BUILD_PID" 2>/dev/null; do
        sleep 5; SECS=$((SECS + 5))
        (( SECS % 60 == 0 )) && info "still building… ($((SECS / 60)) min)"
      done
      wait "$BUILD_PID"; BUILD_RC=$?
      set -e
      if [[ $BUILD_RC -ne 0 || ! -x "$ROOT/build/Tether.app/Contents/MacOS/Tether" ]]; then
        grep -E 'error:|fatal' "$LOG" | tail -5 | sed 's/^/    /' >&2 || true
        die "The build failed. Full log: $LOG"
      fi
      # Same stamp setup.sh uses, so running setup again doesn't rebuild.
      ( git_ rev-parse HEAD; git_ status --porcelain ) | shasum | cut -c1-16 > "$ROOT/build/.source-stamp"
    fi
    ok "built"

    step "Installing"
    STEP="installing"; status running "Installing and restarting Tether"
    LOGINS="$(plist allowedLogins "$CONFIG")"; PORT="$(plist port "$CONFIG")"
    [[ -n "$LOGINS" ]] || die "Tether's settings on this Mac are missing. Run scripts/setup.sh once."
    if [[ -n "$DRY" ]]; then
      echo "dry run: install-agent.sh $LOGINS ${PORT:-7400} $ROOT"
    else
      rsync -a --delete "$ROOT/build/Tether.app/" "$INSTALLED/"
      OUT="$(bash "$ROOT/scripts/lib/install-agent.sh" "$LOGINS" "${PORT:-7400}" "$ROOT" "" 2>&1)" \
        || { printf '%s\n' "$OUT" | sed 's/^/  /' >&2; die "Installing failed (see ~/Library/Logs/Tether-update.log)."; }
      printf '%s\n' "$OUT" | grep -v '^TETHER_RESULT' || true
    fi
    STEP="done"; status done "Updated to ${TO:0:7}"
    ok "Tether is updated (${TO:0:7})"
  fi
elif [[ $ALL == 0 ]]; then
  if [[ -x "$INSTALLED/Contents/MacOS/Tether" ]]; then
    die "Tether on this Mac updates from $(plist sourceDir "$CONFIG"), not from this folder."
  fi
  die "Tether isn't installed on this Mac. To update your other Macs, run: scripts/update.sh --all"
fi

# ── Other Macs ────────────────────────────────────────────────────────────────
if [[ $ALL == 1 ]]; then
  FAILED=()
  for env in "$HOME"/.config/tether/targets/*.env; do
    [[ -f "$env" ]] || continue
    name="$(basename "$env" .env)"
    step "Updating \"$name\""
    if [[ -n "$DRY" ]]; then echo "dry run: deploy.sh $name"; continue; fi
    if ! "$ROOT/scripts/deploy.sh" "$name" 2>&1 | sed 's/^/  /'; then FAILED+=("$name"); fi
  done
  [[ ${#FAILED[@]} -eq 0 ]] || fail "Couldn't update: ${FAILED[*]} (see above)."
fi
echo
ok "Done"
