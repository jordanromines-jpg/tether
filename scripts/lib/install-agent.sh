#!/usr/bin/env bash
# Runs ON the Mac being controlled (locally, or piped over SSH by setup.sh/deploy.sh).
# Expects ~/Applications/Tether.app to already be in place. Idempotent.
#
#   install-agent.sh <allowed-logins> [port]
#
# Installs/refreshes the login agent, publishes it to the tailnet with `tailscale serve`
# (when HTTPS certificates are enabled) and prints a machine-readable summary line:
#   TETHER_RESULT url=<https url> certs=<yes|no> screen=<true|false> input=<true|false>
set -euo pipefail
LOGINS="${1:?allowed logins required}"
PORT="${2:-7400}"
LABEL="com.tether.agent"
APP="$HOME/Applications/Tether.app"
[[ -x "$APP/Contents/MacOS/Tether" ]] || { echo "  ✗ $APP is missing" >&2; exit 1; }

if command -v tailscale >/dev/null 2>&1; then TS="$(command -v tailscale)"; else TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale; fi
read -r DNS CERTS < <("$TS" status --json | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(d["Self"]["DNSName"].rstrip("."), "yes" if d.get("CertDomains") else "no")')
URL="https://$DNS"

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>Program</key><string>$APP/Contents/MacOS/Tether</string>
  <key>AssociatedBundleIdentifiers</key><string>$LABEL</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>TETHER_PORT</key><string>$PORT</string>
    <key>TETHER_ALLOWED_LOGINS</key><string>$LOGINS</string>
    <key>TETHER_PUBLIC_URL</key><string>$URL</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/Tether.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/Tether.log</string>
</dict>
</plist>
PL
DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# bootout finishes asynchronously (a busy app can take several seconds); retry for up to 20s.
for attempt in $(seq 1 20); do
  launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null && break
  if [[ $attempt == 20 ]]; then
    echo "  ✗ Couldn't start Tether. This Mac must be logged in at its desktop (not just the login screen)." >&2
    echo "    Log in on that Mac, then run setup again." >&2
    exit 1
  fi
  sleep 1
done
launchctl kickstart -k "$DOMAIN/$LABEL"
echo "  ✓ Tether is running and will start automatically at login"

if [[ "$CERTS" == yes ]]; then
  "$TS" serve --bg --https=443 "http://127.0.0.1:$PORT" >/dev/null
  echo "  ✓ published on your tailnet at $URL"
fi

# Ask the agent for its permission state, presenting the first allowed login.
FIRST_LOGIN="${LOGINS%%,*}"
HEALTH=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  HEALTH="$(curl -s -m 2 -H "Tailscale-User-Login: $FIRST_LOGIN" "http://127.0.0.1:$PORT/healthz" || true)"
  [[ "$HEALTH" == *'"ok"'* ]] && break
  sleep 1
done
read -r SCREEN INPUT < <(printf '%s' "$HEALTH" | python3 -c 'import json,sys
try: p=json.load(sys.stdin)["perms"]; print(str(p["screen"]).lower(), str(p["input"]).lower())
except Exception: print("unknown unknown")')
echo "TETHER_RESULT url=$URL certs=$CERTS screen=$SCREEN input=$INPUT"
