# Shared helpers for Tether scripts. Source, don't execute.
# Status lines are written for a non-technical reader (and for Claude to relay):
#   ✓  done            →  in progress            ✗  problem
#   ACTION NEEDED      a step only the person at the Mac can do; the script stops (exit 3)

TETHER_LABEL="com.tether.agent"
TETHER_PORT="${TETHER_PORT:-7400}"

ok()    { printf '  ✓ %s\n' "$*"; }
step()  { printf '\n→ %s\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
fail()  { printf '  ✗ %s\n' "$*" >&2; exit 1; }
action_needed() {
  printf '\nACTION NEEDED\n' >&2
  for line in "$@"; do printf '  %s\n' "$line" >&2; done
  printf '\nWhen that is done, run this setup again. It picks up where it left off.\n' >&2
  exit 3
}

# Prints the path to the tailscale CLI, or nothing.
tailscale_cli() {
  if command -v tailscale >/dev/null 2>&1; then command -v tailscale
  elif [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then echo /Applications/Tailscale.app/Contents/MacOS/Tailscale
  fi
}

# tailscale_json <python expression over `d`>  e.g. tailscale_json 'd["BackendState"]'
tailscale_json() {
  local ts; ts="$(tailscale_cli)"; [[ -n "$ts" ]] || return 1
  "$ts" status --json 2>/dev/null | python3 -c "import json,sys
d=json.load(sys.stdin)
v=$1
print(v if not isinstance(v,(list,dict)) else json.dumps(v))" 2>/dev/null
}

tailscale_login() { tailscale_json 'd["User"][str(d["Self"]["UserID"])]["LoginName"]'; }

# Shortcut registry (~/Library/Application Support/Tether/shortcuts.json, a JSON array of paths),
# read and written with plutil so the controlled Mac needs no extra tools.
registry_paths() {
  local f="$1" i=0 v
  [[ -s "$f" ]] || return 0
  while v="$(plutil -extract "$i" raw -o - "$f" 2>/dev/null)"; do printf '%s\n' "$v"; i=$((i + 1)); done
}
registry_add() {
  local f="$1" p="$2" n
  mkdir -p "$(dirname "$f")"
  [[ -s "$f" ]] || echo '[]' > "$f"
  registry_paths "$f" | grep -qxF "$p" && return 0
  n="$(registry_paths "$f" | wc -l | tr -d ' ')"
  plutil -insert "$n" -string "$p" "$f"
}
