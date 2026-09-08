# LocalNook — architecture

## Origin

LocalNook is a derivative of [boring.notch](https://github.com/TheBoredTeam/boring.notch)
(GPL-3.0), audited at commit `99900bf`. Upstream ships as an Xcode project; this
Mac has Command Line Tools but not full Xcode, so `xcodebuild`, `actool` and
`ibtool` are unavailable and the `.xcodeproj` cannot be built at all. LocalNook
therefore keeps upstream's *architecture* and rebuilds it on Swift Package
Manager, which works fine under CLT.

What was carried over, and what was replaced, is itemised in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

## Toolchain notes

Two things are unusual and worth knowing before you touch the build.

### `defaultIsolation(MainActor.self)`

`Package.swift` builds in Swift 6 language mode with
`.defaultIsolation(MainActor.self)`. Almost every type in a UI app of this shape
is main-actor-bound, so making that the default removes hundreds of `@MainActor`
annotations. The exceptions are marked `nonisolated` explicitly, and each one is
a deliberate statement that the type is safe off the main actor:

| Type | Why nonisolated |
|---|---|
| `NotchShape` | `Shape` conformance must be nonisolated |
| `ElevatedWindowSpace` | `deinit` must tear down the space without hopping actors |
| `MediaScriptBridge` | AppleScript runs on its own serial queue |
| `CaptureSessionBox` | `AVCaptureSession` configuration blocks; owns its queue |
| `DirectoryWatcher` | `DispatchSource` callbacks arrive on a utility queue |
| `SessionAgent` | Pure value type read by the background scanner |

### `@LNState`

In the macOS 27 SDK, `State` is declared **twice**: as the familiar
`@propertyWrapper struct State<Value>` and as an attached macro implemented by
the `SwiftUIMacros` compiler plugin. Overload resolution prefers the macro — but
that plugin ships only with full Xcode, so plain `@State` fails to compile under
Command Line Tools with *"plugin for module 'SwiftUIMacros' not found"*.

A typealias can only name the *type*, never the macro, so
`typealias LNState<Value> = SwiftUI.State<Value>` unambiguously selects the
property-wrapper form. Behaviour is identical; only the spelling differs. If you
ever build with full Xcode installed, plain `@State` would work too — the shim
stays correct either way, so there is nothing to undo. See
`Core/SwiftUICompat.swift`.

## The notch window

### Fixed panel, animated content

The single most important structural decision, inherited from upstream:

> **The panel never resizes. The SwiftUI content animates inside it.**

`NotchPanel` is created at `NotchGeometry.windowSize(for:)` — wide enough for
the expanded panel plus its corner flares, drop shadow and the side gutters that
live activities need — and stays that size forever. Opening and closing animates
the *drawn shape* within that fixed window. Resizing an `NSPanel` every frame
produces visible tearing; animating content does not.

A consequence worth knowing: `NSHostingView` will otherwise propagate its
content's ideal size up to the window and silently widen it, knocking the notch
off centre. `host.sizingOptions = []` prevents that. This was a real bug — the
panel came out 44pt too wide and 22pt off-centre.

### Two windows: drawing and interaction

The panel lies across the top of the screen, above the menu bar. Anything it
hit-tests, it steals — a click that lands on it never reaches Chrome, the menu
bar, or whatever else is underneath. Collapsed, it was taking every click in a
944×214 strip, which made the top of the display unusable for other apps.

**Declining the hit test does not fix this.** `NSWindow` dispatches to the view
`hitTest` returns; when that is `nil` the event is *dropped*, not forwarded to
the window below. The click is swallowed silently — indistinguishable from the
original bug. (`NSHostingView` also hit-tests to itself for every point in its
bounds regardless of what SwiftUI drew, and `.allowsHitTesting(false)` changes
nothing, because AppKit never asks SwiftUI.)

The only mechanism that genuinely routes a click past a window is
`ignoresMouseEvents`, and it is all-or-nothing per window. So the two
responsibilities are split:

| Window | Size | Role |
|---|---|---|
| `NotchPanel` | as wide as it needs to draw (up to ~945pt) | Draws everything. **Inert while collapsed.** |
| `NotchHitPanel` | exactly the notch (~209×35) | Invisible. **The only window accepting input while collapsed.** |

While the notch is open the roles swap: the panel is visible and covers real
content, so it takes input and the catcher stands down. `syncInteractivity()`
keeps exactly one of them live.

Measured effect: the interactive footprint went from 944×214 to 209×35 — a 96%
reduction — and now sits inside the physical notch, which is not usable screen
area anyway.

`NotchHitTestView` still restricts hit-testing *within* the panel, as a second
layer of defence for the expanded state.

#### Consequences worth knowing

- **Live-activity wings are display-only.** When something is playing the drawn
  strip stretches to ~445pt, but neither hover nor clicks follow it. Tracking
  that width would expand the notch whenever the pointer crossed the top of the
  screen. The wings still *cover* menu-bar space visually; turn individual
  activities off in Settings ▸ Live Activities if that is unwanted.
- **Hover lives on the catcher, not the panel.** Collapsed, the panel is inert,
  so its tracking area never fires. A hover test written against the panel will
  keep passing even if hover is completely broken — `testCatcherHover` drives
  the shipped catcher for this reason.
- **A deliberate close latches shut** until the pointer leaves, otherwise the
  catcher re-opens the notch immediately under a stationary cursor.

### Window configuration

`NotchPanel` is a borderless, **non-activating** `NSPanel` at level
`.popUpMenu` (101), which places it above the menu bar. Clicking it must never
steal focus from the user's frontmost app, so `canBecomeKey` is gated on
`allowsKeyStatus`, which the controller sets **only while the notch is open** —
otherwise Notes and To-Do could not accept typing at all.

`collectionBehavior` is `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary,
.ignoresCycle]`, and `sharingType = .none` keeps the panel out of window pickers
and screen sharing.

### Geometry

`NotchGeometry` resolves the closed size:

- **Physical notch:** width from `screen.frame.width - auxiliaryTopLeftArea.width
  - auxiliaryTopRightArea.width`, plus a 4pt bleed so no hairline of wallpaper
  shows beside the shape. Height follows the user's mode: real notch inset, menu
  bar height, or custom.
- **No physical notch:** a virtual notch at the user's configured size, or
  nothing if disabled.

`NotchShape` draws the silhouette: two **concave** flares at the top blending
into the screen edge, two **convex** rounded corners at the bottom. The flares
are drawn *inside* the shape's rect, so the opaque body spans
`rect.width - 2 × topRadius`; `NotchShape.totalWidth(forBody:topRadius:)` sizes
the container to compensate.

### The dead zone

While expanded, the top `closedHeight` points of the panel sit **behind the
physical camera housing** and are invisible on a real notched Mac. Nothing
readable may go there. `ExpandedNotchView` reserves that strip for "shoulder"
content either side of the housing — widget title on the left, settings and
collapse on the right — and puts the tab strip and widget body below it. This
was also a real bug: the first layout put the widget rail in that strip.

### Pages and the Dashboard

The expanded notch has three pages, selected from pills in the left shoulder:
**Dashboard**, **Tray**, **Tools**. This replaced a strip of ten widget icons
that showed one widget at a time and left most of the panel empty.

`DashboardView` lays complementary sections out by weight, but a section that
cannot reach `dashboardMinimumWidth` is **dropped rather than squeezed** —
making everything slightly too small to read is worse than showing one fewer
thing. A widget switched off in Settings is omitted, never silently replaced by
a fallback, because a fallback would put back exactly what the user removed.

Two consent rules the composition forced into the open, both now covered by
tests:

- **Calendar must not prompt.** The Dashboard opens on hover, so
  `refreshIfAuthorized()` reads events only when consent already exists and
  never triggers a dialog. Asking is an explicit button.
- **The camera must not start implicitly.** `MirrorManager.activate()` refuses
  to start capture unless `requestStart()` has recorded a real user request.
  The Mirror card is a button; a panel rebuild, a hover, or an offscreen render
  cannot light the camera. Releasing the last preview withdraws the request
  again. Owner-based reference counting still governs shutdown across displays.

### Notch surface

`NotchSurface` paints the notch either opaque black or in macOS 26 Liquid Glass.
The decision lives in a static function rather than the view so it can be tested
without an environment, and it turns on one rule:

> Collapsed, on a display with a real camera housing, the notch **must** be
> opaque black. It is imitating the housing; a translucent panel over an opaque
> cutout reads as a smudge, not an effect.

Expanded — or on any display without a housing — glass applies. `glassEffect` is
macOS 26+, so it sits behind an availability check and degrades to solid rather
than failing to build or launch.

The dark scrim under the glass is functional, not decorative: glass does not
guarantee contrast, and widget text over a bright wallpaper is unreadable
without it.

Solid black carries **no border and no gradient** — the silhouette and a
restrained shadow do the work. Glass gets a single hairline, because it has no
colour of its own and otherwise loses its edge against a busy desktop.

### External displays

"Show on every display" defaults **on**, so a second monitor gets a notch out of
the box. Displays without a camera housing draw a virtual notch instead; with
`matchRealNotch` selected — the default — there is no real notch to measure, so
the height falls back to the configured virtual height rather than collapsing to
nothing.

Geometry is expressed as a pure `NotchGeometry.DisplayMetrics` value rather than
reading `NSScreen` directly. The external-display path is the one most likely to
break and least likely to be plugged in while working on it, so this makes it
testable without hardware: virtual sizing, menu-bar-relative height, the
disabled case, and placement on displays whose frame origin is offset — positive
*and* negative, which is how a second monitor ends up drawing its notch on the
wrong screen.

### Multi-display and system events

`NotchWindowController` owns one panel and one `NotchViewModel` per target
display, keyed by a **stable display UUID** (`CGDisplayCreateUUIDFromDisplayID`)
rather than by `NSScreen`, which is recreated on every configuration change.

It rebuilds on: `didChangeScreenParameters` (coalesced by 350 ms, because macOS
emits a burst while a display is attaching), wake (600 ms delay — display
geometry can change during sleep), space changes, and screen lock/unlock.

### Hover must not need Accessibility

The obvious implementation is a global event monitor:

```swift
NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { ... }
```

**On macOS 27 that never fires without Accessibility.** Measured directly on this
machine: with `AXIsProcessTrusted() == false`, a global `.mouseMoved` monitor
received **0 of 12** synthesised moves. Hover would have been silently dead for
anyone who had not granted Accessibility — a permission LocalNook otherwise
never asks for.

Hover therefore uses `NSTrackingArea` (`HoverTracker`), which the window server
delivers to the owning window with no permission at all. The area is sized to
the *interactive region* — the notch when collapsed, the whole panel when
expanded — because the panel is far wider than the visible notch and tracking
all of it would fire on any pointer crossing the top of the screen.
`.activeAlways` is essential: LocalNook is an accessory app and is almost never
frontmost, so `.activeInActiveApp` would mean hover effectively never fires.

The global monitor survives only as an *optional* enhancement for
click-somewhere-else-to-collapse. Nothing essential depends on it; without it,
moving the pointer off the notch still closes it.

## Feature modules

Each feature is a manager (state, system integration) plus a view. Managers are
`ObservableObject` singletons.

### Media

`MediaProvider` is the abstraction; `MusicAppProvider` and `SpotifyProvider`
implement it over **Apple Events**.

**Why not MediaRemote.** Apple restricted the private MediaRemote framework in
macOS 15.4. Upstream works around this by bundling `MediaRemoteAdapter`, a
prebuilt binary framework. That framework is legitimately licensed (BSD-3), but
it is an opaque binary that cannot be audited from source, and the spec for this
project forbids shipping copied binaries. Apple Events are public, documented and
user-consented.

**What that costs.** Apple Events only reach apps with a scripting dictionary.
Music and Spotify work; browser tabs do not. This is a real functional gap and is
recorded in TODO.md rather than papered over.

**Polling discipline** matters more than anything else here, because an
always-on 1 Hz AppleScript poll is exactly what keeps a laptop awake:

- No supported app **running** → do not poll at all. Launches and quits arrive as
  `NSWorkspace` notifications.
- Something playing → poll at the configured interval.
- Everything paused, notch closed → back off to 5 s.
- Asleep → stop entirely.

Scripts are compiled once and cached, and executed on a dedicated serial queue
because `NSAppleScript` is not thread-safe.

### Shelf

`ShelfStore` holds items and persists an index to JSON. Files are **referenced in
place** — dropping a file records its path, it does not copy it. Only content
with no file of its own (dragged text) is written into LocalNook's storage, and
only those items (`isOwned`) are deleted when removed. Entries whose file has
since moved are dropped on load, so no row can be un-actionable.

The drop target is deliberately *not* the whole panel: when collapsed it stays
close to the notch, because the panel is far wider than the visible notch and a
full-width drop zone would hijack drags passing near the top of the screen.

### Calendar, Mirror

EventKit and AVFoundation respectively, both requesting access on first use of
the widget. The camera session is torn down in `onDisappear` so the green
recording light never outlives the visible preview. `MirrorManager` passes a
**device ID** rather than an `AVCaptureDevice` across the concurrency boundary,
because the device is not `Sendable`.

### Timers

Elapsed time is derived from wall-clock `Date` values, not accumulated per tick,
so timers stay accurate across sleep and dropped ticks. The 0.2 s tick only
drives redraws and exists only while something is running.

### Sessions

Watches `~/.claude/projects` and `~/.codex/sessions` via `DispatchSource`
file-system events — kernel notifications, not a polling timer.

**It reads file metadata only** (`URLResourceValues`: path, mtime, size). It
never opens a transcript or reads a line of any conversation, and project names
come from directory names. See docs/SECURITY_AUDIT.md § 9.

### Live activities

`LiveActivityCenter` converts system events into the pills shown beside the
collapsed notch. Everything is push-driven: battery from IOKit power-source
run-loop callbacks, audio devices from a CoreAudio property listener, timers and
media from Combine publishers. Transient banners self-dismiss; persistent ones
(media playing, timer running) last as long as their state does. A HUD change
outranks everything, because the user just pressed a key.

## Permissions

Nothing is requested at launch. `Permissions` reads current state without
prompting; each feature requests its own on first use. Automation is special —
macOS offers no read-only API for it, so its state is inferred from whether the
last Apple Event returned error `-1743`.

## Persistence

`@Pref` (see `Core/Preferences.swift`) persists a property to `UserDefaults` and
republishes the owning `ObservableObject` on change, using the enclosing-instance
subscript so a plain `var` gets both with no boilerplate. Values are cached in
memory so hover ticks and animation frames never hit the defaults database.
Primitives are stored natively (so `defaults read` is legible); everything else
is JSON.

## Private APIs

Exactly one file: `Vendor/ElevatedWindowSpace.swift`, the CoreGraphics Spaces
wrapper that can float the panel above full-screen apps.

- **Off by default** (Settings ▸ Notch ▸ Advanced).
- Symbols resolved with `dlsym`, not `@_silgen_name`, so a future macOS removing
  them yields `nil` and a silent fall back to normal window levels — never a
  launch-time crash.
- MPL-2.0, adapted from Parrot via boring.notch; notice retained in the file.

## Packaging

`scripts/build-release.sh` compiles with SwiftPM, hand-assembles the `.app`
bundle (there is no `actool`, so there is no asset catalog — the icon is
generated by `scripts/make-icon.swift` and `iconutil`), writes `Info.plist`,
ad-hoc signs, and builds a DMG with `hdiutil`. The licence text is copied into
the bundle because the GPL requires recipients be able to obtain it.

`--render-preview <dir>` renders the notch states offscreen to PNGs. It exists
because verifying a UI that draws over the menu bar otherwise needs Screen
Recording permission.
