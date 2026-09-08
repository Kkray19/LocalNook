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

### Multi-display and system events

`NotchWindowController` owns one panel and one `NotchViewModel` per target
display, keyed by a **stable display UUID** (`CGDisplayCreateUUIDFromDisplayID`)
rather than by `NSScreen`, which is recreated on every configuration change.

It rebuilds on: `didChangeScreenParameters` (coalesced by 350 ms, because macOS
emits a burst while a display is attaching), wake (600 ms delay — display
geometry can change during sleep), space changes, and screen lock/unlock.

Hover and click are driven by global `NSEvent` monitors testing the pointer
against a hit region — the closed notch when collapsed, the full open panel when
expanded — rather than by SwiftUI hover alone, which cannot see the pointer
before it enters the window.

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
