#!/usr/bin/env bash
# Builds build/Tether.app (release) with the web client bundled, signed with the stable
# identity from scripts/setup-signing.sh (or ad-hoc if that hasn't been set up).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Tether.app"
BUNDLE_ID="com.tether.agent"
VERSION="$(git -C "$ROOT" describe --always --dirty 2>/dev/null || echo dev)"
# The version people see ("6.0"); see CHANGELOG.md.
RELEASE="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || true)"; RELEASE="${RELEASE:-0}"
# Which GitHub repo this was built from (help links and update checks follow forks), and when
# its commit was made. TETHER_BUILD_DATE overrides the date (used to test the update banner).
REPO="$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#^.*github\.com[:/]##')"
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || REPO="jordanromines-jpg/tether"
BUILD_DATE="${TETHER_BUILD_DATE:-$(git -C "$ROOT" log -1 --format=%cI 2>/dev/null || true)}"
# The exact commit, so the update check can list what's new and the web page can tell it changed.
COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"

echo "› swift build (release)"
swift build -c release --package-path "$ROOT/agent"
BIN="$(swift build -c release --package-path "$ROOT/agent" --show-bin-path)/Tether"

echo "› assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tether"
cp -R "$ROOT/web" "$APP/Contents/Resources/web"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ROOT/web/icons/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ROOT/web/icons/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Tether</string>
  <key>CFBundleDisplayName</key><string>Tether</string>
  <key>CFBundleExecutable</key><string>Tether</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$RELEASE</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>TetherRepo</key><string>$REPO</string>
  <key>TetherBuildDate</key><string>$BUILD_DATE</string>
  <key>TetherCommit</key><string>$COMMIT</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>Tether Setup Assistant</string>
    <key>CFBundleURLSchemes</key><array><string>tether</string></array>
  </dict></array>
</dict>
</plist>
PLIST

# Sign with the stable self-signed identity (scripts/setup-signing.sh) so macOS keeps
# Screen Recording / Accessibility grants across rebuilds. Falls back to ad-hoc.
KC="$HOME/Library/Keychains/tether-signing.keychain-db"
PWFILE="$HOME/.config/tether/signing-keychain-password"
if [[ -f "$KC" && -f "$PWFILE" ]]; then
  security unlock-keychain -p "$(cat "$PWFILE")" "$KC"
  IDENTITY="$(security find-identity -p codesigning "$KC" | awk '/Tether Signing/ {print $2; exit}')"
  # codesign only sees identities in keychains on the search list: add ours for the
  # duration of the signing step, then restore the user's list exactly.
  ORIG_LIST=()
  while IFS= read -r line; do ORIG_LIST+=("$(echo "$line" | sed -E 's/^ *"(.*)"$/\1/')"); done < <(security list-keychains -d user)
  trap 'security list-keychains -d user -s "${ORIG_LIST[@]}"' EXIT
  security list-keychains -d user -s "${ORIG_LIST[@]}" "$KC"
  codesign --force --sign "$IDENTITY" --keychain "$KC" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
  security list-keychains -d user -s "${ORIG_LIST[@]}"
  trap - EXIT
  echo "› signed with stable identity \"Tether Signing\""
else
  echo "! no stable signing identity; using ad-hoc (permissions reset on every build). Run scripts/setup-signing.sh"
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi
echo "✓ built $APP ($VERSION)"
