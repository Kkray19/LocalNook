# Third-party licences

LocalNook itself is licensed **GNU GPL v3.0 or later** (see `LICENSE`), because
it is a derivative work of boring.notch.

LocalNook has **zero Swift Package Manager dependencies**. Everything it needs
comes from the macOS SDK. The list below is therefore short by design — it
covers upstream provenance and the one file adapted from another project.

---

## 1. boring.notch — GPL-3.0-or-later

- **Upstream:** <https://github.com/TheBoredTeam/boring.notch>
- **Copyright:** © The Boring Team and contributors
- **Licence:** GNU General Public License v3.0 or later
- **Reference commit audited:** `99900bf630a3d3e97fae079df2175993318d51f7`

LocalNook is a derivative work. The following architecture and techniques were
studied and re-implemented from boring.notch:

| Technique | Where it lives in LocalNook |
|---|---|
| Deriving physical notch width from `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` | `Core/ScreenGeometry.swift` |
| Fixed-size panel with animated SwiftUI content (rather than resizing the window) | `Notch/NotchWindowController.swift`, `UI/NotchRootView.swift` |
| Borderless non-activating `NSPanel` above the menu bar | `Notch/NotchPanel.swift` |
| Per-display view models keyed by a stable display UUID | `Notch/NotchViewModel.swift` |
| Rebuilding panels on screen-parameter, sleep/wake and lock/unlock events | `Notch/NotchWindowController.swift` |
| Notch silhouette with concave top flares and convex bottom corners | `UI/NotchShape.swift` |

**Because LocalNook is a derivative work of GPL-3.0 software, LocalNook is also
distributed under GPL-3.0-or-later.** The full licence text ships in the app
bundle at `LocalNook.app/Contents/Resources/LICENSE`.

## 2. CGSSpace wrapper — MPL-2.0

- **File:** `Sources/LocalNook/Vendor/ElevatedWindowSpace.swift`
- **Originally from:** Parrot — <https://github.com/avaidyam/Parrot>, by way of boring.notch
- **Licence:** Mozilla Public License 2.0 (retained in the file header)

Adapted, not copied verbatim: LocalNook resolves the private symbols through
`dlsym` instead of `@_silgen_name` so a missing symbol degrades gracefully
rather than crashing at launch. This file is **opt-in and off by default**
(Settings ▸ Notch ▸ Advanced).

---

## Deliberately **not** used

| Thing | Why not |
|---|---|
| **NotchNook** (any source, asset, icon, graphic or branding) | Proprietary. Nothing from it was consulted, copied or adapted. All LocalNook artwork is drawn in code in `UI/Glyph.swift` and `scripts/make-icon.swift`. |
| **Sparkle** (upstream dependency) | It is a network auto-updater. LocalNook's spec requires no network activity, so it was dropped rather than ported. |
| **MediaRemoteAdapter** (BSD-3-Clause, bundled by upstream) | Legitimately licensed, but ships as a **prebuilt binary framework** that cannot be audited from source. LocalNook uses public Apple Events instead. See ARCHITECTURE.md § Media for the trade-off this makes. |
| `Defaults`, `LaunchAtLogin-Modern`, `KeyboardShortcuts`, `Lottie`, `Pow`, `MacroVisionKit`, `SkyLightWindow`, `AsyncXPCConnection` | All replaced with SDK equivalents (`UserDefaults`, `SMAppService`, native SwiftUI animation) to keep the build fully offline and dependency-free. |

## System frameworks used

AppKit, SwiftUI, Combine, Foundation, AVFoundation, EventKit, UserNotifications,
ServiceManagement, CoreGraphics, IOKit, CoreBluetooth. All part of macOS and
covered by the Apple SDK licence.
