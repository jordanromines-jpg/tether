#!/usr/bin/env bash
# Makes shortcuts for Tether. Applications is the default folder; pass another folder to choose,
# or run it in Terminal with no folder to pick one in a Finder dialog.
#
#   scripts/shortcut.sh app [folder]                    # on the Mac you control: a "Tether" shortcut that starts Tether
#   scripts/shortcut.sh app [folder] --remote <target>  # the same, on another Mac set up with setup.sh --remote
#                                                       #   (<target> is a saved name like "studio", or user@machine)
#   scripts/shortcut.sh viewer <name|url> [folder]      # on the Mac you control FROM: a "Tether - <name>" app that
#                                                       #   opens that Mac's screen in its own window
#   scripts/shortcut.sh updater [folder]               # on the Mac that installs Tether on others: a "Tether Updater"
#                                                       #   app that updates this Mac and every saved Mac in one click
#
# Shortcuts are listed in ~/Library/Application Support/Tether/shortcuts.json so scripts/uninstall.sh
# removes exactly these.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/common.sh"

KIND="${1:-}"; shift || true
ARG=""; FOLDER=""; REMOTE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote) REMOTE="${2:?--remote needs a target name or user@machine}"; shift ;;
    -h|--help) sed -n 2,16p "$0"; exit 0 ;;
    *) if [[ "$KIND" == viewer && -z "$ARG" ]]; then ARG="$1"; else FOLDER="$1"; fi ;;
  esac
  shift
done
[[ "$KIND" == app || "$KIND" == viewer || "$KIND" == updater ]] || { sed -n 2,16p "$0" >&2; exit 2; }

# The folder: given, or picked in a Finder dialog when someone is at the keyboard, else Applications.
pick_folder() {
  if [[ -n "$FOLDER" ]]; then echo "${FOLDER/#\~/$HOME}"; return; fi
  if [[ -t 0 && -t 1 && -z "$REMOTE" ]]; then
    osascript -e 'POSIX path of (choose folder with prompt "Where should the Tether shortcut go?" default location (POSIX file "/Applications"))' 2>/dev/null \
      || { echo "  Cancelled. No shortcut was made." >&2; exit 0; }
    return
  fi
  echo /Applications
}

if [[ "$KIND" == app ]]; then
  DIR="$(pick_folder)"; DIR="${DIR%/}"
  CMD="\"\$HOME/Applications/Tether.app/Contents/MacOS/Tether\" --make-alias $(printf '%q' "$DIR")"
  if [[ -n "$REMOTE" ]]; then
    HOST="$REMOTE"; KEY=""
    if [[ -f "$HOME/.config/tether/targets/$REMOTE.env" ]]; then
      # shellcheck disable=SC1090
      source "$HOME/.config/tether/targets/$REMOTE.env"; KEY="${SSH_KEY:-}"; KEY="${KEY/#\~/$HOME}"
    fi
    SSH_OPTS=(-o ConnectTimeout=8 -o BatchMode=yes)
    [[ -n "$KEY" && -f "$KEY" ]] && SSH_OPTS+=(-i "$KEY" -o IdentitiesOnly=yes)
    OUT="$(ssh "${SSH_OPTS[@]}" "$HOST" "$CMD" 2>&1)" || fail "Couldn't add the shortcut on ${HOST#*@}: $OUT"
  else
    [[ -x "$HOME/Applications/Tether.app/Contents/MacOS/Tether" ]] || fail "Tether isn't installed on this Mac yet. Run scripts/setup.sh first."
    OUT="$(bash -c "$CMD" 2>&1)" || fail "Couldn't add the shortcut: $OUT"
  fi
  ok "added a Tether shortcut: $OUT"
  exit 0
fi

# ---- updater: a tiny app that runs scripts/update.sh --all in a Terminal window ----
if [[ "$KIND" == updater ]]; then
  DIR="$(pick_folder)"; DIR="${DIR%/}"
  [[ -w "$DIR" ]] || { info "$DIR isn't writable, using ~/Applications instead"; DIR="$HOME/Applications"; mkdir -p "$DIR"; }
  APP="$DIR/Tether Updater.app"
  REG="$HOME/Library/Application Support/Tether/shortcuts.json"
  if [[ -e "$APP" ]] && ! registry_paths "$REG" | grep -qxF "$APP"; then
    fail "There's already something called \"Tether Updater.app\" in $DIR that Tether didn't make. Pick another folder."
  fi
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  for c in "$ROOT/build/Tether.app" "$HOME/Applications/Tether.app"; do
    [[ -f "$c/Contents/Resources/AppIcon.icns" ]] && { cp "$c/Contents/Resources/AppIcon.icns" "$APP/Contents/Resources/"; break; }
  done
  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.tether.updater-app</string>
  <key>CFBundleName</key><string>Tether Updater</string>
  <key>CFBundleExecutable</key><string>open-updater</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
  cat > "$APP/Contents/Resources/update.command" <<SCRIPT
#!/bin/bash
# Updates Tether on this Mac (if it's installed here) and on every Mac saved in ~/.config/tether/targets.
cd $(printf '%q' "$ROOT") && scripts/update.sh --all
echo
read -n 1 -s -r -p "Press any key to close this window."
SCRIPT
  printf '#!/bin/bash\nexec open -a Terminal "$(dirname "$0")/../Resources/update.command"\n' > "$APP/Contents/MacOS/open-updater"
  chmod +x "$APP/Contents/MacOS/open-updater" "$APP/Contents/Resources/update.command"
  touch "$APP"
  registry_add "$REG" "$APP"
  ok "made \"Tether Updater\" in $DIR. Open it to update Tether everywhere in one click."
  exit 0
fi

# ---- viewer: a tiny app on THIS Mac that opens the other Mac's Tether page in its own window ----
[[ -n "$ARG" ]] || fail "Say which Mac: scripts/shortcut.sh viewer <saved name, machine name, or https link>"
if [[ "$ARG" == https://* ]]; then
  URL="${ARG%/}"
  NAME="$(sed -E 's#https://([^.]+).*#\1#' <<<"$URL")"
else
  HOSTNAME="$ARG"
  if [[ -f "$HOME/.config/tether/targets/$ARG.env" ]]; then
    HOSTNAME="$(sed -nE 's/^HOST=(.*@)?([^.]+).*/\2/p' "$HOME/.config/tether/targets/$ARG.env")"
  fi
  TS="$(tailscale_cli)"; [[ -n "$TS" ]] || fail "Tailscale isn't installed on this Mac."
  SELF_DNS="$("$TS" status --json | plutil -extract Self.DNSName raw -o - - 2>/dev/null || true)"
  [[ "$SELF_DNS" == *.* ]] || fail "Couldn't read your tailnet name from Tailscale. Is it signed in?"
  SUFFIX="${SELF_DNS#*.}"; SUFFIX="${SUFFIX%.}"
  URL="https://$HOSTNAME.$SUFFIX"
  NAME="$ARG"
fi
DIR="$(pick_folder)"; DIR="${DIR%/}"
[[ -w "$DIR" ]] || { info "$DIR isn't writable, using ~/Applications instead"; DIR="$HOME/Applications"; mkdir -p "$DIR"; }
APP="$DIR/Tether - $NAME.app"
REG="$HOME/Library/Application Support/Tether/shortcuts.json"
if [[ -e "$APP" ]] && ! registry_paths "$REG" | grep -qxF "$APP"; then
  fail "There's already something called \"$(basename "$APP")\" in $DIR that Tether didn't make. Pick another folder."
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ICON=""
for c in "$ROOT/build/Tether.app" "$HOME/Applications/Tether.app"; do
  [[ -f "$c/Contents/Resources/AppIcon.icns" ]] && { cp "$c/Contents/Resources/AppIcon.icns" "$APP/Contents/Resources/"; ICON=AppIcon; break; }
done
ID="com.tether.viewer.$(tr -cd 'A-Za-z0-9' <<<"$NAME" | tr 'A-Z' 'a-z')"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>Tether - $NAME</string>
  <key>CFBundleExecutable</key><string>open-tether</string>
  <key>CFBundleIconFile</key><string>$ICON</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
cat > "$APP/Contents/MacOS/open-tether" <<SCRIPT
#!/bin/bash
# Opens Tether for $NAME in its own window: Chrome, Edge or Brave app mode if one is installed,
# otherwise the default browser (in Safari, File > Add to Dock makes it a standalone app).
URL="$URL"
for b in "Google Chrome" "Microsoft Edge" "Brave Browser"; do
  if open -Ra "\$b" 2>/dev/null; then exec open -na "\$b" --args --app="\$URL"; fi
done
exec open "\$URL"
SCRIPT
chmod +x "$APP/Contents/MacOS/open-tether"
touch "$APP"

# Record it for uninstall.
registry_add "$REG" "$APP"
ok "made \"$(basename "$APP")\" in $DIR. It opens $URL"
if [[ "$DIR" == /Applications || "$DIR" == "$HOME/Applications" ]]; then
  info "Find it in Launchpad or Spotlight, or drag it to the Dock."
fi
