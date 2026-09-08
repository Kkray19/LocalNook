# Changelog

All notable changes to LocalNook. Format loosely follows Keep a Changelog.

## [Unreleased]

### Added
- Core notch system: borderless non-activating `NSPanel` pinned above the menu
  bar, physical-notch geometry detection, virtual notch for displays without one.
- Hover / click open with configurable open and close delays; Escape collapses.
- Multi-display support with per-display view models keyed by stable display UUID;
  rebuilds on display connect/disconnect, resolution change, sleep/wake and
  lock/unlock.
- Dependency-free settings store (`@Pref`) persisting to `UserDefaults`.
- Settings window: General, Notch, Widgets, Live Activities, HUD, Privacy, About.
- Permission inspector showing the live state of every permission LocalNook can ask for.
- Original app icon and menu-bar glyph, both drawn in code.
- `scripts/build-release.sh`: one-command `.app` + `.dmg` build needing only
  Command Line Tools.

### Notes
- Built from boring.notch's architecture (GPL-3.0-or-later); LocalNook keeps that licence.
- Zero Swift Package Manager dependencies. No network access, account, licence
  check, update check or telemetry.
