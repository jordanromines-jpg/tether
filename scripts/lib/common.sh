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
