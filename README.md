# LocalNook

A local-first notch utility for macOS. It turns the area around the MacBook
camera notch into a Dynamic Island-style panel: media controls, a drag-and-drop
shelf, calendar, camera mirror, timers, notes, to-dos, Shortcuts, system stats,
and a live view of your Claude Code and Codex sessions.

**No subscription. No account. No licence server. No telemetry. No network
access at all** — see [docs/SECURITY_AUDIT.md](docs/SECURITY_AUDIT.md), which
verifies that claim at source, binary and runtime level.

---

## What it does

**Collapsed**, LocalNook is invisible — it sits exactly inside your physical
notch. When something happens it widens and shows a *live activity* flanking the
camera housing: what's playing, a running timer, charging state, AirPods
connecting, or an agent session going quiet.

**Expanded** (hover or click), it opens into a panel with a widget strip:

| Widget | What it does |
|---|---|
| **Media** | Now Playing from Music and Spotify: artwork, scrubbing, transport |
| **Shelf** | Drag files in, drag them back out. Quick Look, multi-select, persists across launches |
| **Calendar** | Today's events via EventKit, with day navigation |
| **Mirror** | Live camera preview, including Continuity Camera |
| **Timers** | Countdown, stopwatch and pomodoro, with notifications |
| **Notes / To-Do** | Local, searchable, autosaving |
| **Shortcuts** | Lists and runs your macOS Shortcuts; pin the ones you use |
| **AI Sessions** | Which Claude Code / Codex sessions are working, and which have gone quiet |
| **Stats** | Battery, memory and storage |

> **Note:** NotchNook is currently installed and running on this Mac. It draws
> its own notch UI, and LocalNook floats above it. They do not conflict, but
> quit NotchNook if you want to see LocalNook's own appearance clearly.

## System requirements

- macOS 15 or later (built and tested on macOS 27)
- Apple Silicon
- **Xcode Command Line Tools** — full Xcode is *not* required

```bash
xcode-select --install
```

## Build

```bash
cd ~/Developer/LocalNook
./scripts/build-release.sh
```

That produces `dist/LocalNook.app` and `dist/LocalNook.dmg`. Options:

```bash
./scripts/build-release.sh --no-dmg   # app only
./scripts/build-release.sh --debug    # faster, unoptimised
```

The build needs no network access, no Apple Developer account and no paid
signing certificate. The app is ad-hoc signed, which is sufficient to run and to
hold permissions on the Mac that built it.

## Install

```bash
cp -R dist/LocalNook.app /Applications/
open /Applications/LocalNook.app
```

LocalNook has no Dock icon — it lives in the notch and the menu bar. Click the
menu bar glyph for Settings, or press ⌘, when Settings is focused.

> **Install it before enabling "Launch at login."** macOS refuses to register a
> login item for an app running out of a build directory; LocalNook will show
> you the error rather than silently failing.

## Controlling it from a script

LocalNook listens for distributed notifications, so a Shortcut, an Automation
action or a shell script can drive it — no Accessibility permission needed:

```bash
# Open, close or toggle the notch on the display under the pointer
osascript -e 'tell application "System Events" to return' >/dev/null 2>&1
python3 -c "
from Foundation import NSDistributedNotificationCenter
NSDistributedNotificationCenter.defaultCenter().postNotificationName_object_userInfo_deliverImmediately_(
    'com.localnook.toggle', None, None, True)"
```

Names: `com.localnook.open`, `com.localnook.close`, `com.localnook.toggle`.

## Permissions

LocalNook asks for nothing at launch. Each permission is requested the first
time you use the feature that needs it, and refusing one disables only that
feature.

| Permission | Needed for | If you say no |
|---|---|---|
| **Calendar** | The Calendar widget | Widget explains and offers a Settings link |
| **Camera** | The Mirror widget | Same. Video is *previewed only* — never recorded or saved |
| **Notifications** | Timer alerts | Falls back to an audible beep |
| **Automation** | Reading/controlling Music and Spotify | Media widget explains and offers a link |
| **Accessibility** | **Never requested** | — |

Settings ▸ Privacy shows the live state of all of these, with buttons that jump
to the right System Settings pane.

## Where your data lives

| What | Where |
|---|---|
| Settings | `~/Library/Preferences/com.localnook.app.plist` |
| Shelf index | `~/Library/Application Support/LocalNook/shelf.json` |
| Notes and to-dos | `~/Library/Application Support/LocalNook/notes.json` |
| Text dropped on the shelf | `~/Library/Application Support/LocalNook/ShelfItems/` |

Files you drop on the shelf are **referenced in place, not copied**. Removing a
shelf item never deletes your file — LocalNook only deletes files it created
itself (dragged text with no file of its own).

## Uninstall

```bash
rm -rf /Applications/LocalNook.app
rm -rf ~/Library/Application\ Support/LocalNook
defaults delete com.localnook.app
```

If you enabled Launch at login, turn it off in Settings first (or remove it in
System Settings ▸ General ▸ Login Items).

## Rebuilding this years from now

The build has **zero Swift Package Manager dependencies**, so it does not depend
on any package host still existing. You need only:

1. A Mac with Command Line Tools (`xcode-select --install`)
2. This repository
3. `./scripts/build-release.sh`

If a future Swift version rejects something, the two places most likely to need
attention are documented in [ARCHITECTURE.md](ARCHITECTURE.md) § Toolchain notes:
the `@LNState` shim and the `defaultIsolation(MainActor.self)` setting in
`Package.swift`.

## Licence

**GNU General Public License v3.0 or later.**

LocalNook is a derivative work of
[boring.notch](https://github.com/TheBoredTeam/boring.notch) © The Boring Team,
which is GPL-3.0, so LocalNook carries the same licence. You may study, modify
and redistribute it under those terms. See [LICENSE](LICENSE) and
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

No NotchNook source, assets, icons, artwork or branding were used. All LocalNook
artwork is drawn in code (`UI/Glyph.swift`, `scripts/make-icon.swift`).
