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
mkdir -p "$DIST"
LOCK="$ROOT/.release-lock"
mkdir "$LOCK" 2>/dev/null || { echo "Another release build holds $LOCK" >&2; exit 1; }
WORK="$(mktemp -d "$DIST/.release.XXXXXX")"
cleanup() { rm -rf "$WORK" "$LOCK"; }
trap cleanup EXIT
# Stale outputs must never look like the result of a failed invocation.
rm -rf "$DIST/$APP_NAME.app" "$DIST/$APP_NAME.dmg"
APP="$WORK/$APP_NAME.app"
COMMIT="$(git rev-parse HEAD)"
BUILD_TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
BUILD_ID="$(uuidgen)"
MARKER="$WORK/started"
touch "$MARKER"
CONTENTS="$APP/Contents"

step() { printf "\033[1;34m==>\033[0m %s\n" "$1"; }

# ── 1. Compile ───────────────────────────────────────────────────────────────
step "Testing release failure gates…"
python3 "$ROOT/scripts/test-release.py"
step "Testing install failure gates…"
# Runs entirely in temporary directories it creates and deletes; it never
# targets, stops or reads the real installation in /Applications.
python3 "$ROOT/scripts/test-install.py" | sed "s/^/    /"
step "Building $APP_NAME ($CONFIG) for arm64…"
swift package clean
swift build -c "$CONFIG" --arch arm64

BINARY="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/$APP_NAME"
[ -x "$BINARY" ] && [ "$BINARY" -nt "$MARKER" ] || { echo "build produced no binary at $BINARY" >&2; exit 1; }

# ── 2. Assemble the bundle ───────────────────────────────────────────────────
step "Assembling $APP_NAME.app…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BINARY" "$CONTENTS/MacOS/$APP_NAME"
cmp "$BINARY" "$CONTENTS/MacOS/$APP_NAME"
SOURCE_SHA="$(shasum -a 256 "$BINARY" | cut -d ' ' -f1)"

# Licence documents travel with the app: the GPL requires that recipients can
# get the licence text, and the About pane links to these.
cp "$ROOT/LICENSE" "$CONTENTS/Resources/LICENSE"
cp "$ROOT/MPL-2.0.txt" "$CONTENTS/Resources/MPL-2.0.txt"
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
    <key>LocalNookCommit</key><string>$COMMIT</string>
    <key>LocalNookBuiltAt</key><string>$BUILD_TIMESTAMP</string>
    <key>LocalNookBuildID</key><string>$BUILD_ID</string>
    <key>LocalNookSourceSHA256</key><string>$SOURCE_SHA</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <!-- Accessory app: lives in the notch and menu bar, no Dock icon. -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Krish Kowli. GNU GPL v3.0 or later. Derived from boring.notch.</string>

    <!-- Purpose strings. macOS shows these verbatim in its permission prompts,
         so each one states exactly what the feature does with the data. -->
    <key>NSCalendarsUsageDescription</key>
    <string>LocalNook shows your upcoming events in the notch. Events are read on this Mac and never leave it.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>LocalNook shows your upcoming events in the notch. Events are read on this Mac and never leave it.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>LocalNook reads what is playing and sends play, pause and skip commands to your music apps.</string>

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
ICONSET="$WORK/AppIcon.iconset"
swift "$ROOT/scripts/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# ── 4. Sign ──────────────────────────────────────────────────────────────────
# Ad-hoc signature. It is enough for the app to run and to hold TCC permissions
# on this Mac, and it needs no paid Apple Developer account.
step "Signing (ad-hoc)…"
codesign --force --deep --sign - \
         --options runtime \
         --identifier "$BUNDLE_ID" \
         "$APP" 2>&1 | sed 's/^/    /'
codesign --verify --deep --strict "$APP" && echo "    signature verified"

# ── 4b. Self-test ────────────────────────────────────────────────────────────
# Gates the release on the built bundle actually working. Skippable for a
# quick iteration, but never skipped by default.
if true; then
  UNVERIFIED_AT_RELEASE=0
  step "Running the deterministic suite…"
  # The deterministic half gates the release: it injects pointer position,
  # button state, display configuration and scheduling, so a failure here is a
  # real defect rather than a machine that would not deliver an event.
  set +e
  "$CONTENTS/MacOS/$APP_NAME" --self-test --deterministic | sed 's/^/    /'
  DETERMINISTIC_RC=${PIPESTATUS[0]}
  set -e
  case "$DETERMINISTIC_RC" in
    0) echo "    deterministic suite passed" ;;
    2)
      # Every deterministic check injects what it needs, so nothing here should
      # ever be unable to run. If one is, the seam it depends on has been lost.
      echo "    DETERMINISTIC CHECK COULD NOT RUN — this half injects its own" >&2
      echo "    preconditions, so an unverified result means a broken seam." >&2
      exit 1
      ;;
    *)
      echo "    DETERMINISTIC SUITE FAILED — not packaging" >&2
      exit 1
      ;;
  esac

  # The live integration half gates on defects and not on the environment.
  #
  # "Advisory by definition" is the wrong policy: it means a demonstrated
  # product defect can ship because of which half of the suite happened to find
  # it. "Always gating" is also wrong: it reddens the build because the window
  # server declined to deliver a crossing for a window moved under a still
  # pointer, which is the harness's limitation, not the app's.
  #
  # So the suite distinguishes the two and the exit code carries it:
  #   0  everything asserted and held
  #   1  a check failed — a delivered event mishandled, or a wrong final state.
  #      A demonstrated defect. BLOCKS the release, from either half.
  #   2  nothing failed, but something could not be exercised. Does not block;
  #      carried forward as an explicit limitation.
  step "Running live integration checks…"
  set +e
  "$CONTENTS/MacOS/$APP_NAME" --self-test --integration 2>&1 | sed 's/^/    /'
  INTEGRATION_RC=${PIPESTATUS[0]}
  set -e
  case "$INTEGRATION_RC" in
    0)
      echo "    integration checks passed"
      ;;
    2)
      echo "    integration checks passed, with unverified scenarios (see above)."
      echo "    Not a release blocker; recorded as a limitation."
      UNVERIFIED_AT_RELEASE=1
      ;;
    *)
      echo "    INTEGRATION CHECK FAILED — a delivered event was mishandled or a" >&2
      echo "    final state was wrong. That is a product defect. Not packaging." >&2
      exit 1
      ;;
  esac
fi

# ── 5. DMG ───────────────────────────────────────────────────────────────────
if [ "$MAKE_DMG" -eq 1 ]; then
  step "Building $APP_NAME.dmg…"
  DMG="$WORK/$APP_NAME.dmg"
  STAGE="$WORK/dmg-stage"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cp "$ROOT/LICENSE" "$STAGE/LICENSE"
  rm -f "$DMG"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
  rm -rf "$STAGE"
  echo "    $(du -h "$DMG" | cut -f1) → $DMG"
fi

# Staging bundles must not linger in LaunchServices.
#
# Each build stages the .app inside dist/.release.XXXXXX/, macOS registers it on
# sight, and the directory is then deleted — leaving a registration pointing at
# nothing. Thirty-seven of those had accumulated by the time anyone looked, and
# while `open -a LocalNook` still resolved to /Applications, a launch route that
# depends on which of forty registrations wins is not one to rely on.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$APP" 2>/dev/null || true

# Only publish verified artifacts after every gate succeeds.
"$CONTENTS/MacOS/$APP_NAME" --version
[ "$MAKE_DMG" -eq 0 ] || hdiutil verify "$DMG"
mv "$APP" "$DIST/$APP_NAME.app"
APP="$DIST/$APP_NAME.app"
[ "$MAKE_DMG" -eq 0 ] || mv "$DMG" "$DIST/$APP_NAME.dmg"
step "Done."
if [ "${UNVERIFIED_AT_RELEASE:-0}" -eq 1 ]; then
  printf "\033[1;33m    NOTE:\033[0m this build has unverified scenarios. See the integration\n"
  printf "    output above and docs/MANUAL_CHECKS.md. It is not fully verified.\n"
fi
echo "    App: $APP"
[ "$MAKE_DMG" -eq 1 ] && echo "    DMG: $DIST/$APP_NAME.dmg"
echo
echo "Install with:  ./scripts/install.sh"
echo "               (validates first, keeps a recoverable copy, restores on failure)"
