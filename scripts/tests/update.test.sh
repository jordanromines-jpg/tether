#!/usr/bin/env bash
# Tests scripts/update.sh against a throwaway "GitHub" (a local bare repo) and a fake install,
# with the build and install stubbed out (TETHER_UPDATE_DRY_RUN=1). Touches nothing real.
#   bash scripts/tests/update.test.sh
set -uo pipefail
REAL="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home" TETHER_UPDATE_DRY_RUN=1 GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export TMPDIR="$T/tmp"; mkdir -p "$HOME" "$TMPDIR"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); echo "  ✓ $1"; else FAIL=$((FAIL + 1)); echo "  ✗ $1"; echo "$OUT" | sed 's/^/      /'; fi; }

# "GitHub": a bare repo with the scripts update.sh needs, published as github.com/test/tether.
git init -q --bare -b main "$T/origin.git"
git init -q -b main "$T/seed"
mkdir -p "$T/seed/scripts/lib"
cp "$REAL/scripts/update.sh" "$T/seed/scripts/"; cp "$REAL/scripts/lib/common.sh" "$T/seed/scripts/lib/"
echo one > "$T/seed/file.txt"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm one && git -C "$T/seed" push -q "$T/origin.git" main
publish() {   # a new commit on "GitHub"; $1 = message, $2 = optional sed edit to update.sh
  echo "$1" >> "$T/seed/file.txt"
  [[ -n "${2:-}" ]] && sed -i '' "$2" "$T/seed/scripts/update.sh"
  git -C "$T/seed" commit -qam "$1" && git -C "$T/seed" push -q "$T/origin.git" main
}
fresh_clone() {
  rm -rf "$T/clone"
  git clone -q "$T/origin.git" "$T/clone"
  git -C "$T/clone" remote set-url origin https://github.com/test/tether.git
  git -C "$T/clone" config url."$T/origin.git".insteadOf https://github.com/test/tether.git
}
install_here() {   # $1 = commit the "installed" app was built from, $2 = repo it came from
  local app="$HOME/Applications/Tether.app/Contents"
  mkdir -p "$app/MacOS" "$HOME/Library/Application Support/Tether"
  printf '#!/bin/sh\n' > "$app/MacOS/Tether"; chmod +x "$app/MacOS/Tether"
  plutil -create xml1 "$app/Info.plist"
  plutil -insert TetherRepo -string "${2:-test/tether}" "$app/Info.plist"
  plutil -insert TetherCommit -string "$1" "$app/Info.plist"
  printf '{"allowedLogins":"me@example.com","port":7400,"publicURL":"https://x","sourceDir":"","updateFrom":""}\n' \
    > "$HOME/Library/Application Support/Tether/config.json"
}
STATUS="$T/status.json"
run() { OUT="$(bash "$T/clone/scripts/update.sh" --status-file "$STATUS" "$@" 2>&1)"; RC=$?; }
state() { plutil -extract "$1" raw -o - "$STATUS" 2>/dev/null; }

echo "update.sh"
fresh_clone; install_here "$(git -C "$T/clone" rev-parse HEAD)"
run
check "already up to date: exit 0 and status 'current'" '[[ $RC == 0 && "$(state state)" == current && "$OUT" == *"already up to date"* ]]'

publish two 's/^FROM="\${FROM:-\$(git_ rev-parse HEAD)}"; TO=.*$/&\necho UPDATE_SH_V2/'
NEW="$(git -C "$T/seed" rev-parse HEAD)"
run
check "fast-forward: pulls, builds, installs, status 'done'" '[[ $RC == 0 && "$(git -C "$T/clone" rev-parse HEAD)" == "$NEW" && "$(state state)" == done && "$OUT" == *"dry run: install-agent.sh me@example.com 7400 $T/clone"* ]]'
check "fast-forward: the NEW update.sh runs after the pull" '[[ "$OUT" == *UPDATE_SH_V2* ]]'
check "fast-forward: status records from and to" '[[ "$(state to)" == "$NEW" && -n "$(state from)" && "$(state from)" != "$NEW" ]]'
check "the temporary copies are cleaned up" '[[ -z "$(ls "$TMPDIR")" ]]'

echo change >> "$T/clone/file.txt"
run
check "local changes: refused, file untouched, specific status kept" '[[ $RC == 1 && "$(state state)" == failed && "$(state message)" == *"changes of its own that aren"* && "$(tail -1 "$T/clone/file.txt")" == change ]]'
git -C "$T/clone" checkout -q file.txt

git -C "$T/clone" commit -q --allow-empty -m local; publish three
run
check "diverged: refused" '[[ $RC == 1 && "$OUT" == *"commits of its own"* ]]'

fresh_clone; install_here "$(git -C "$T/clone" rev-parse HEAD)" other/tether
run
check "wrong repo: refused" '[[ $RC == 1 && "$OUT" == *"pulls from"* && "$OUT" == *"github.com/other/tether"* ]]'

fresh_clone; install_here "$(git -C "$T/clone" rev-parse HEAD)"
git -C "$T/clone" checkout -qb feature
run
check "not on main: refused" '[[ $RC == 1 && "$OUT" == *"not main"* ]]'

fresh_clone; rm -rf "$HOME/Applications" "$HOME/Library"
run
check "not installed here, no --all: explains --all" '[[ $RC == 1 && "$OUT" == *"update.sh --all"* ]]'
mkdir -p "$HOME/.config/tether/targets"; echo HOST=me@studio > "$HOME/.config/tether/targets/studio.env"
run --all
check "--all: updates every saved Mac" '[[ $RC == 0 && "$OUT" == *"dry run: deploy.sh studio"* ]]'

echo "$PASS passed, $FAIL failed"
[[ $FAIL == 0 ]]
