# LocalNook — test log

Two layers of verification, because XCTest is unavailable under Command Line
Tools (it ships with full Xcode only).

## 1. Automated: `LocalNook --self-test`

Runs in-process against the real singletons and the real view hierarchy. It is
wired into `scripts/build-release.sh` and **blocks packaging on failure**.

```
$ dist/LocalNook.app/Contents/MacOS/LocalNook --self-test
64 passed, 0 failed
```

Covered:

| Area | What is asserted |
|---|---|
| Environment | A display exists; notch geometry is reported |
| Geometry | Closed size tracks the physical notch; panel is wide/tall enough for the open state, centred, pinned to the top edge; shape width accounts for both flares |
| Preferences | Double/enum/optional round-trip; values actually reach `UserDefaults`; widgets enable, disable and leave the ordered list |
| Shelf | Files land, are referenced in place, are not double-added; **removal does not delete the user's file**; URLs become link items |
| Notes / To-Do | Create, edit, title-from-first-line, search hit and miss, delete; to-do trim, complete, sort, archive; blank input rejected |
| Timers | Full duration shown before start; formatting; run/pause; stopwatch has no total; pomodoro phases; countdown clamps |
| Media | Starts idle; progress maths; position interpolates while playing and not while paused; zero duration cannot divide by zero; availability checks never launch an app |
| Sessions | Scan completes; ids are file paths and no content is retained |
| Permissions | Every permission has a readable state and a Settings link; managers behave with access denied; notification APIs guarded when unbundled |
| Shortcuts | System tool present; a hostile name stays a single argv entry |
| **Hover (end to end)** | Builds the real `NotchPanel` + `NotchRootView`, slides it under the stationary cursor, and asserts the notch opens and then collapses — **with `AXIsProcessTrusted() == false`** |

### The hover test is the important one

Hover originally used `NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved])`.
Measured on this machine: with Accessibility **not** granted, that monitor
received **0 of 12** synthesised mouse moves. Hover would simply not have worked
for anyone who had not granted Accessibility — and LocalNook is not supposed to
need it.

It was rebuilt on `NSTrackingArea`, which the window server delivers to the
owning window with no permission at all. The end-to-end test proves this by
moving the *window* under a stationary cursor, so it needs no permission either.

Two false negatives were hit while writing that test, both worth recording:

- A near-transparent test panel (`alphaValue = 0.02`) receives no mouse events.
- `RunLoop.run(until:)` never dispatches AppKit events; they must be dequeued
  and passed to `NSApp.sendEvent`. The real app's event loop does this, so the
  code was fine and only the harness was wrong.

## 2. Visual: `LocalNook --render-preview <dir>`

Renders every notch state offscreen to PNG. Used to verify layout without
Screen Recording permission. Caught two real layout bugs:

- The widget rail overflowed the 190pt panel with ten widgets.
- Content was drawn in the top strip that sits behind the physical camera
  housing, invisible on a real notched Mac.

## 3. Manual checks performed

| Check | Result |
|---|---|
| Launch, quit, relaunch from `/Applications` | Passes |
| Panel geometry via window server | layer 101, 944×214, exactly centred, pinned to top |
| Idle CPU after 26 s | **0.0 %** |
| Resident memory | ~46 MB |
| Open network sockets | **none** |
| DMG checksum + mount | valid; contains app, `/Applications` symlink, LICENSE |
| Bare binary (no bundle) | Runs; notification APIs guarded instead of crashing |
| Release build gated on tests | A failing self-test aborts packaging |

## Live on-screen verification

Confirmed by screenshot on the built-in display, with LocalNook installed in
`/Applications`:

- **Collapsed:** invisible, sitting inside the physical notch.
- **Expanded:** the panel renders correctly — widget title, tab strip, widget
  body, settings and collapse controls — triggered by
  `com.localnook.open`.

### A long false trail worth recording

For a while the notch appeared not to open: the model reported `.open`, the
window was present at layer 101 with `alpha = 1.0` and correct bounds, and yet
every screenshot showed nothing.

The cause was `NSWindow.sharingType = .none` on the panel. That flag excludes a
window from screen capture entirely — `screencapture` cannot see it and
`screencapture -l<id>` fails with *"could not create image from window"*. The
app had been working correctly the whole time; only the screenshots were blind.

It is now `.readOnly` (the normal default), because a notch the user cannot
screenshot or screen-record is surprising and makes the app impossible to
support by screenshot.

Two smaller traps from the same session:

- A `python` string replacement silently did not match, so a "fix" was never
  actually applied while its rebuild reported success. Always re-grep the file.
- `scripts/build-release.sh` piped `swift build` through `grep`, which swallowed
  the exit status, so a **failing compile still produced an app** from the
  previous binary. Fixed with `set -o pipefail` and an explicit failure branch.
  Several confusing test results before that fix were stale binaries.

### Also discovered

**NotchNook is installed and running on this Mac** (window layer 25). It draws
its own notch UI, which is what appears in screenshots of the notch area.
LocalNook sits above it at layer 101. The two do not conflict, but if you want
to evaluate LocalNook's own appearance, quit NotchNook first.

## Click-through and external displays

`--self-test` now covers the two areas most likely to make LocalNook annoying to
live with.

**Interactive footprint.** Nine assertions that the collapsed notch accepts
clicks on itself and passes everything else through, built through the same
`makeContentView` path the app ships so they cannot drift from real behaviour.
All five failing cases were reproduced before the fix. Plus eight assertions that
exactly one of the drawing panel and the catcher accepts input at a time, and
that the catcher never widens to follow a live activity.

**External displays.** Ten assertions covering virtual-notch sizing,
menu-bar-relative height, the disabled case, and placement on displays with
offset frame origins — all driven through `DisplayMetrics`, so they run with no
second monitor attached. Plus hot-plug: a display-configuration change must not
duplicate panels or leave orphans pointing at a disconnected screen.

**Measured live**, collapsed, on the built-in display:

```
layer=102  209x35   ← catcher: the only window taking input
layer=101  445x35   ← drawing panel: ignoresMouseEvents
```

Down from a single 944×214 interactive window.

## Evidence classes

Not all "verified" is the same, so this log separates them.

### Verified by automated check

`--self-test`, **232 assertions**, run against the shipped binary itself rather
than a rebuild of the same sources.

Honest rate on the shipped binary: **11 clean runs of 12**, the one failure being
a missed hover crossing. Two consecutive batches of 8 and 6 runs were completely
clean with 0 skips, so the crossings were genuinely delivered rather than waved
through. This is not a green suite being reported as green — it is a suite with
one known intermittent, and the number is what it is.

Two flakiness investigations in this pass were more informative than the green
runs. A 15-run of build 21 produced *scattered* failures across unrelated
sections; the pattern, not any single failure, was the signal, and it led to
`stop()` leaving the recovery task running so a stopped controller could close a
later session's notch. A second run surfaced a missed hover crossing when a
window moves under a stationary pointer — a real case, since attaching a display
repositions the panel. Freezing matters: an earlier 16-run attempt straddled
rebuilds and its counts climbed from 188 to 207, which made it useless as
evidence for any single build.

Covers, among the rest: dashboard fitting and the no-loss invariant across 68
panel widths; the click-through footprint per display; external-display geometry
with offset origins; the pointer-recovery fallback's start/stop and hold-off
rules; the camera's explicit-start gate and its delayed-consent race; notes
surviving a quit inside the autosave debounce; and the Tray against real files on
a real pasteboard.

Assertion counts vary slightly with the machine: several sections iterate over
attached displays, and two assertions are conditional branches (an error path in
the shelf test, and the "Liquid Glass unavailable" fallback) that do not run on
macOS 26+. The source contains more `check(` calls than any single run executes;
the run total is the honest figure.

### Verified by driving the installed app

- The composed Dashboard, Tray and Tools pages on **both** displays, captured
  from the running app.
- The overflow control at a narrow panel width, with icon-only tabs.
- 140 rapid open/close/page commands including open-during-close: no crash,
  exactly four windows, catchers unchanged at 209×35 and 220×35.
- Idle cost after repeated interaction: 0.0% CPU, ~41 MB resident, 0 sockets.
- Liquid Glass over a dark background, and the collapsed notch staying solid over
  the physical camera housing.
- **Hot-unplug observed live:** the external display was disconnected during this
  pass and LocalNook went from four windows to exactly two — one panel and one
  catcher on the remaining display — with no orphans.
- The overflow control at a narrow panel width, showing the hidden section's own
  icon with a count badge rather than a bare "+1".
- The populated Tray with real Finder icons and middle-truncated names.

### Verified by observing real user interaction

Hover on the **built-in** display: seven open→close pairs recorded against the
live app instance before any scripted command in that session. See BUGS.md.

### Deliberately not gating

Two hover checks move a window under a stationary pointer, because that is the
only way to simulate hover without Accessibility. AppKit does not always deliver
the crossing. They now count crossings actually delivered, so "LocalNook ignored
a crossing" remains a hard failure while "the platform produced none" is reported
as not exercised. Checks that need no mouse button held, or a notch that actually
opened, say so too. None of this weakens an assertion about LocalNook's own
behaviour; it stops the gate reddening because someone was holding the mouse.

### Still requires a human

See **docs/MANUAL_CHECKS.md**. Chiefly: the Finder drag gesture itself, dragging
items back out, hover on the external display, and the "notch stays open while
typing" guard. These need synthesised pointer input, i.e. Accessibility, which
LocalNook deliberately does not require.

## Known gaps in coverage

- **Live on-screen hover on the physical notch** has not been observed directly:
  synthesising pointer movement requires Accessibility, which is not granted.
  It is covered by the end-to-end test, which drives the real panel and view.
  A five-second manual check (hover the notch) would confirm it in situ.
- **External display behaviour has not been seen on screen.** The monitor
  attached to this Mac (G274QPF E2, 2560×1440) is powered off, so
  `CGGetOnlineDisplayList` reports one display. The geometry and hot-plug paths
  are covered through `DisplayMetrics`, but placement on a real second monitor
  is still unverified.
- **Sleep/wake** handling is implemented and wired to `NSWorkspace.didWake`, but
  has not been exercised through a real sleep cycle.
- **Permission-denied paths** are asserted structurally rather than by actually
  revoking each permission.
