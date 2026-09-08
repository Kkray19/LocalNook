#!/bin/bash
#
# build-release.sh — build LocalNook.app and LocalNook.dmg from source.
#
# Copyright (C) 2026 Krish Kowli
# Licensed under the GNU General Public License v3.0 or later. See LICENSE.
#
# Requires only Xcode Command Line Tools (no full Xcode, no Apple Developer
# account, no network access). Usage:
#
#   ./scripts/build-release.sh          # build .app and .dmg
#   ./scripts/build-release.sh --no-dmg # build .app only
#   ./scripts/build-release.sh --debug  # debug configuration, faster
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="LocalNook"
BUNDLE_ID="com.localnook.app"
VERSION="$(cat VERSION 2>/dev/null || echo "0.1.0")"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
CONFIG="release"
MAKE_DMG=1

for arg in "$@"; do
  case "$arg" in
    --no-dmg) MAKE_DMG=0 ;;
    --debug)  CONFIG="debug" ;;
    -h|--help) sed -n '3,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"

step() { printf "\033[1;34m==>\033[0m %s\n" "$1"; }

# ── 1. Compile ───────────────────────────────────────────────────────────────
step "Building $APP_NAME ($CONFIG) for arm64…"
swift build -c "$CONFIG" --arch arm64 2>&1 \
  | grep -vE "ld: warning: (search path|Could not find or use auto-linked framework 'CoreAudioTypes'|Could not parse or use implicit file .*SwiftUICore)" \
  || true

BINARY="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/$APP_NAME"
[ -f "$BINARY" ] || { echo "build produced no binary at $BINARY" >&2; exit 1; }

# ── 2. Assemble the bundle ───────────────────────────────────────────────────
step "Assembling $APP_NAME.app…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BINARY" "$CONTENTS/MacOS/$APP_NAME"

# Licence documents travel with the app: the GPL requires that recipients can
# get the licence text, and the About pane links to these.
cp "$ROOT/LICENSE" "$CONTENTS/Resources/LICENSE"
[ -f "$ROOT/THIRD_PARTY_LICENSES.md" ] && cp "$ROOT/THIRD_PARTY_LICENSES.md" "$CONTENTS/Resources/"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <!-- Accessory app: lives in the notch and menu bar, no Dock icon. -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Krish Kowli. GNU GPL v3.0 or later. Derived from boring.notch.</string>

    <!-- Purpose strings. macOS shows these verbatim in its permission prompts,
         so each one states exactly what the feature does with the data. -->
    <key>NSCameraUsageDescription</key>
    <string>LocalNook shows a live camera preview in the Mirror widget. Video is displayed only — nothing is recorded, saved or sent anywhere.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>LocalNook shows your upcoming events in the notch. Events are read on this Mac and never leave it.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>LocalNook shows your upcoming events in the notch. Events are read on this Mac and never leave it.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>LocalNook reads what is playing and sends play, pause and skip commands to your music apps.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>LocalNook does not record audio. This entry exists only because the camera preview API may request it.</string>

    <key>NSAppleEventsUsageDescriptionTargets</key>
    <array>
        <string>com.apple.Music</string>
        <string>com.spotify.client</string>
    </array>
</dict>
</plist>
PLIST
plutil -lint "$CONTENTS/Info.plist" >/dev/null

printf 'APPL????' > "$CONTENTS/PkgInfo"

# ── 3. Icon ──────────────────────────────────────────────────────────────────
step "Generating app icon…"
ICONSET="$(mktemp -d)/AppIcon.iconset"
if swift "$ROOT/scripts/make-icon.swift" "$ICONSET" >/dev/null 2>&1 \
   && iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns" 2>/dev/null; then
  echo "    icon generated"
else
  echo "    warning: icon generation failed; the app will use the generic icon" >&2
fi
rm -rf "$(dirname "$ICONSET")"

# ── 4. Sign ──────────────────────────────────────────────────────────────────
# Ad-hoc signature. It is enough for the app to run and to hold TCC permissions
# on this Mac, and it needs no paid Apple Developer account.
step "Signing (ad-hoc)…"
codesign --force --deep --sign - \
         --options runtime \
         --identifier "$BUNDLE_ID" \
         "$APP" 2>&1 | sed 's/^/    /' || true
codesign --verify --deep --strict "$APP" && echo "    signature verified"

# ── 5. DMG ───────────────────────────────────────────────────────────────────
if [ "$MAKE_DMG" -eq 1 ]; then
  step "Building $APP_NAME.dmg…"
  DMG="$DIST/$APP_NAME.dmg"
  STAGE="$(mktemp -d)/$APP_NAME"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cp "$ROOT/LICENSE" "$STAGE/LICENSE"
  rm -f "$DMG"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
  rm -rf "$(dirname "$STAGE")"
  echo "    $(du -h "$DMG" | cut -f1) → $DMG"
fi

step "Done."
echo "    App: $APP"
[ "$MAKE_DMG" -eq 1 ] && echo "    DMG: $DIST/$APP_NAME.dmg"
echo
echo "Install with:  cp -R \"$APP\" /Applications/"
