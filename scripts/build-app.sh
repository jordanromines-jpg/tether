#!/usr/bin/env bash
# Builds build/Tether.app (release) with the web client and Sparkle bundled, signed with the stable
# identity from scripts/setup-signing.sh (or ad-hoc if that hasn't been set up).
#
#   scripts/build-app.sh                                  a source build for this Mac (updates through git)
#   scripts/build-app.sh --release --tag v6.1.0-rc1       a download build: universal, updates through Sparkle
#        [--feed test|prod]                               which feed it reads (default: rc tags test, others prod)
#        [--dry-run]                                      print the version, build number and feed, build nothing
#
# A release build needs TETHER_UPDATE_PUBLIC_KEY (the update key's public half, from
# scripts/make-release-keys.sh) and signs with TETHER_SIGNING_IDENTITY from TETHER_SIGNING_KEYCHAIN
# (an unlocked keychain) when they are set. It never builds ad-hoc.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Tether.app"
BUNDLE_ID="com.tether.agent"

die() { echo "✗ $*" >&2; exit 1; }

RELEASE_BUILD=0; TAG=""; FEED=""; DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) RELEASE_BUILD=1 ;;
    --tag) TAG="${2:-}"; shift ;;
    --feed) FEED="${2:-}"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    *) die "unknown option: $1 (see the top of scripts/build-app.sh)" ;;
  esac
  shift
done

# Which GitHub repo this was built from (help links, update checks and the feed follow forks), and when
# its commit was made. TETHER_BUILD_DATE overrides the date (used to test the update banner).
REPO="$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#^.*github\.com[:/]##')"
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || REPO="jordanromines-jpg/tether"

# Release builds number themselves from the tag, so Sparkle orders rc1 < rc2 < final:
# v6.1.0-rc1 → 6010001, v6.1.0-rc2 → 6010002, v6.1.0 → 6010099.
MAX_MINOR=99; MAX_PATCH=99; MAX_RC=98; FINAL_SLOT=99
build_number() {   # $1 = tag; prints the CFBundleVersion
  [[ "$1" =~ ^v([0-9]+)\.([0-9]+)(\.([0-9]+))?(-rc([0-9]+))?$ ]] || die "tag must look like v6.1.0 or v6.1.0-rc1, not '$1'"
  local major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[4]:-0}" rc="${BASH_REMATCH[6]:-}"
  (( 10#$minor <= MAX_MINOR && 10#$patch <= MAX_PATCH )) || die "tag '$1': minor and patch must be at most 99"
  local slot=$FINAL_SLOT
  if [[ -n "$rc" ]]; then
    (( 10#$rc >= 1 && 10#$rc <= MAX_RC )) || die "tag '$1': rc must be 1 to $MAX_RC"
    slot=$((10#$rc))
  fi
  echo $(( 10#$major * 1000000 + 10#$minor * 10000 + 10#$patch * 100 + slot ))
}
feed_url() {   # $1 = test|prod
  case "$1" in
    prod) echo "https://github.com/$REPO/releases/download/appcast/appcast.xml" ;;
    test) echo "https://github.com/$REPO/releases/download/appcast/appcast-test.xml" ;;
    *) die "--feed must be test or prod, not '$1'" ;;
  esac
}

if (( RELEASE_BUILD )); then
  [[ -n "$TAG" ]] || die "--release needs --tag (for example --tag v6.1.0-rc1)"
  if [[ -z "$FEED" ]]; then [[ "$TAG" == *-rc* ]] && FEED=test || FEED=prod; fi
  VERSION="$(build_number "$TAG")"
  RELEASE="${TAG#v}"
  FEED_URL="$(feed_url "$FEED")"
else
  [[ -z "$TAG$FEED" ]] || die "--tag and --feed only go with --release"
  VERSION="$(git -C "$ROOT" describe --always --dirty 2>/dev/null || echo dev)"
  # The version people see ("6.0"); see CHANGELOG.md.
  RELEASE="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || true)"; RELEASE="${RELEASE:-0}"
  FEED_URL=""
fi

if (( DRY_RUN )); then
  echo "version=$RELEASE"
  echo "build=$VERSION"
  echo "feed=$FEED_URL"
  exit 0
fi

PUBLIC_KEY=""
if (( RELEASE_BUILD )); then
  PUBLIC_KEY="${TETHER_UPDATE_PUBLIC_KEY:-}"
  # An Ed25519 public key is 32 bytes: 44 characters of base64.
  [[ "$PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "a release build needs TETHER_UPDATE_PUBLIC_KEY (the update key's public half)"
fi

BUILD_DATE="${TETHER_BUILD_DATE:-$(git -C "$ROOT" log -1 --format=%cI 2>/dev/null || true)}"
# The exact commit, so the update check can list what's new and the web page can tell it changed.
COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"

echo "› swift build (release)"
swift build -c release --package-path "$ROOT/agent"
BIN_DIR="$(swift build -c release --package-path "$ROOT/agent" --show-bin-path)"
BIN="$BIN_DIR/Tether"
if (( RELEASE_BUILD )); then
  # A universal app (Apple silicon and Intel): build Intel in its own scratch folder, then join them.
  X86_SCRATCH="$ROOT/build/swift-x86_64"
  echo "› swift build (release, Intel)"
  swift build -c release --package-path "$ROOT/agent" --scratch-path "$X86_SCRATCH" --triple x86_64-apple-macosx14.0 --product Tether
  X86_BIN="$(swift build -c release --package-path "$ROOT/agent" --scratch-path "$X86_SCRATCH" --triple x86_64-apple-macosx14.0 --show-bin-path)/Tether"
  lipo -create "$BIN" "$X86_BIN" -output "$ROOT/build/Tether-universal"
  BIN="$ROOT/build/Tether-universal"
fi

echo "› assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Tether"
cp -R "$ROOT/web" "$APP/Contents/Resources/web"
# Sparkle (universal already). ditto keeps the framework's symlinks. Its XPC services are only for
# sandboxed apps, which Tether isn't, so they are left out.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ROOT/web/icons/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ROOT/web/icons/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Only release builds carry the feed and the update key: they are what makes Tether update through Sparkle.
SPARKLE_KEYS=""
if (( RELEASE_BUILD )); then
  SPARKLE_KEYS="  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>"
fi

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
$SPARKLE_KEYS
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>Tether Setup Assistant</string>
    <key>CFBundleURLSchemes</key><array><string>tether</string></array>
  </dict></array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Signs inside out: Sparkle's helpers, then the framework, then the app.
sign_all() {   # $@ = codesign options that pick the identity
  local fw="$APP/Contents/Frameworks/Sparkle.framework"
  codesign --force "$@" --timestamp=none "$fw/Versions/B/Autoupdate"
  codesign --force "$@" --timestamp=none "$fw/Versions/B/Updater.app"
  codesign --force "$@" --timestamp=none "$fw"
  codesign --force "$@" --timestamp=none --identifier "$BUNDLE_ID" "$APP"
}

# Sign with a stable identity so macOS keeps Screen Recording / Accessibility grants across rebuilds:
# the release identity when one is given, else this Mac's own (scripts/setup-signing.sh), else ad-hoc.
KC="${TETHER_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/tether-signing.keychain-db}"
NAME="${TETHER_SIGNING_IDENTITY:-Tether Signing}"
PWFILE="$HOME/.config/tether/signing-keychain-password"
if [[ -n "${TETHER_SIGNING_KEYCHAIN:-}" || ( -f "$KC" && -f "$PWFILE" ) ]]; then
  [[ -f "$KC" ]] || die "signing keychain not found: $KC"
  [[ -n "${TETHER_SIGNING_KEYCHAIN:-}" ]] || security unlock-keychain -p "$(cat "$PWFILE")" "$KC"
  IDENTITY="$(security find-identity -p codesigning "$KC" | awk -v n="\"$NAME\"" 'index($0, n) {print $2; exit}')"
  [[ -n "$IDENTITY" ]] || die "no code-signing identity named \"$NAME\" in $KC"
  # codesign only sees identities in keychains on the search list: add ours for the
  # duration of the signing step, then restore the user's list exactly.
  ORIG_LIST=()
  while IFS= read -r line; do ORIG_LIST+=("$(echo "$line" | sed -E 's/^ *"(.*)"$/\1/')"); done < <(security list-keychains -d user)
  trap 'security list-keychains -d user -s "${ORIG_LIST[@]}"' EXIT
  security list-keychains -d user -s "${ORIG_LIST[@]}" "$KC"
  sign_all --sign "$IDENTITY" --keychain "$KC"
  security list-keychains -d user -s "${ORIG_LIST[@]}"
  trap - EXIT
  echo "› signed with stable identity \"$NAME\""
elif (( RELEASE_BUILD )); then
  die "a release build must be signed with a stable identity (set TETHER_SIGNING_KEYCHAIN, or run scripts/setup-signing.sh)"
else
  echo "! no stable signing identity; using ad-hoc (permissions reset on every build). Run scripts/setup-signing.sh"
  sign_all --sign -
fi
codesign --verify --deep --strict "$APP" || die "the signed app failed codesign --verify --deep --strict"
echo "✓ built $APP ($RELEASE, $VERSION)"
