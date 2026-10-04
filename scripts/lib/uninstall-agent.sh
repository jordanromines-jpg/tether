#!/usr/bin/env bash
# Runs ON the controlled Mac (locally, or piped over SSH by scripts/uninstall.sh).
#   uninstall-agent.sh [--all]
# Stops Tether, removes the login item and the app, and stops publishing it on the tailnet.
# --all also deletes its settings (passkeys, pause state, config) and logs.
set -euo pipefail
ALL="${1:-}"
LABEL="com.tether.agent"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null && echo "  ✓ stopped Tether" || true
pkill -x Tether 2>/dev/null && echo "  ✓ quit a running copy" || true
launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true   # clear any saved "don't start at login" override
gone() { [[ -e "$1" ]] && rm -rf "$1" && echo "  ✓ removed $2"; return 0; }
# Shortcuts Tether made (Finder aliases, viewer apps), listed in shortcuts.json. Nothing else is touched.
REG="$HOME/Library/Application Support/Tether/shortcuts.json"
i=0
while [[ -s "$REG" ]] && p="$(plutil -extract "$i" raw -o - "$REG" 2>/dev/null)"; do
  [[ "$p" == /* && -e "$p" ]] && rm -rf "$p" && echo "  ✓ removed the shortcut $p"
  i=$((i + 1))
done
[[ -f "$REG" ]] && echo '[]' > "$REG"
gone "$HOME/Library/LaunchAgents/$LABEL.plist" "the login item"
gone "$HOME/Applications/Tether.app" "~/Applications/Tether.app"

if command -v tailscale >/dev/null 2>&1; then TS="$(command -v tailscale)"; else TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale; fi
if [[ -x "$TS" ]] && "$TS" serve status --json 2>/dev/null | grep -q "127.0.0.1:7400"; then
  "$TS" serve --https=443 off >/dev/null 2>&1 && echo "  ✓ stopped publishing Tether on your tailnet" || true
fi

if [[ "$ALL" == "--all" ]]; then
  gone "$HOME/Library/Application Support/Tether" "Tether's settings and passkeys"
  gone "$HOME/Library/Logs/Tether.log" "the log"
fi
echo "  Note: Tether may still be listed under System Settings → Privacy & Security"
echo "  (Screen Recording, Accessibility). Remove it there with − if you like."
