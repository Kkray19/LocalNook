# LocalNook — test log

Two layers of verification, because XCTest is unavailable under Command Line
Tools (it ships with full Xcode only).

## 1. Automated: `LocalNook --self-test`

Runs in-process against the real singletons and the real view hierarchy.

The suite is in two halves, because they have genuinely different reliability
characteristics and mixing them hides that.

| | `--deterministic` | `--integration` |
|---|---|---|
| What it drives | The controller through injected seams: pointer position, mouse-button state, connected displays, and scheduling | The live window server, asked to deliver a real tracking event |
| Must pass | Every run, on any machine | Not guaranteed — see below |
| Release | **Gates packaging** | Reported, never a gate |

```
$ dist/LocalNook.app/Contents/MacOS/LocalNook --self-test --deterministic
deterministic: 258 passed, 0 failed
```

Running with no flag runs both and reports them on separate lines.

### UNVERIFIED is not a pass

A check whose precondition could not be met prints as `? … — UNVERIFIED` and is
counted in its own column. It is never folded into the pass count, and the
summary says so explicitly. A required integration check that could not run
remains unverified; it is not evidence that the behaviour works.

Note what this rule does **not** license. A missing platform event excuses the
*stimulus* a test could not produce; it never excuses leaving the panel in a
state the user cannot escape. That postcondition — an open notch with the
pointer elsewhere always closes — is asserted separately, deterministically,
against the real controller-owned notch with the pointer injected, so it runs
on every single run rather than only when the flaky stimulus happens to work.

### Hover failures are attributed, not guessed at

`HoverProbe` counts three stages: crossings AppKit delivered, crossings
LocalNook forwarded, and the resulting state. "Hover did not open the notch"
therefore resolves to one of four causes:

| Outcome | Meaning | Ours? |
|---|---|---|
| `preconditionUnmet` | The panel never got under the pointer — the window server clamped the frame | No |
| `noPlatformEvent` | AppKit produced no crossing at all | No |
| `eventDropped` | A crossing arrived and was not forwarded | **Yes** |
| `wrongState` | It was forwarded and the state came out wrong | **Yes** |

Every hover result prints `probe: enters=N exits=N handled=N` alongside it, so
a run that passed and a run that did not can be compared after the fact.

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

`--self-test`, run against the shipped binary itself rather than a rebuild of
the same sources. The batch size and the split between halves are fixed in
`scripts/verify-candidate.sh` *before* any run happens, so a report cannot be
assembled from whichever batches came out clean, and the script aborts if the
binary's hash changes underneath it.

A commit count is a version label; the hash is the only thing that identifies a
binary. Note that there are **two** hashes and they are not interchangeable:

| Where | What it is |
|---|---|
| `LocalNookSourceSHA256` in `Info.plist` | The compiler's output, **before** ad-hoc signing. Reproducible from source; not the file that ships. |
| `dist/SHA256SUMS` | The **shipped** binary and disk image, after signing. This is what an installed copy must match. |

They differ because `codesign` rewrites the Mach-O in place. Embedding the final
hash in the plist is not possible — the signature covers the plist, so the value
would have to be known before it exists.

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

### Verified by driving the installed app — display counts

Every window count in this document is meaningless without the number of
displays that were connected when it was taken, so each says.

| Observation | Displays connected |
|---|---|
| Four windows (two panels, two catchers); Dashboard/Tray/Tools on both | **2** |
| 140 rapid open/close/page commands, exactly four windows | **2** |
| Hot-unplug live: four windows → exactly two, no orphans | **2 → 1** |
| Everything in this pass, including both suites and the final candidate batch | **1** |

The last row is why the multi-display checks in this pass run against a seeded
notch rather than a second monitor: with one display attached, the alternative
was a check that reported a pass without running.

### Verified by observing real user interaction

Hover on the **built-in** display: seven open→close pairs recorded against the
live app instance before any scripted command in that session. See BUGS.md.

### Deliberately not gating

The live integration half moves a window under a stationary pointer, because
that is the only way to simulate hover without Accessibility, and AppKit does
not always deliver the crossing. It is reported, never used as a gate.

What that does and does not cover:

- "LocalNook ignored a crossing it was given" (`eventDropped`) and "it handled
  one and the state came out wrong" (`wrongState`) are **hard failures**. They
  are never reported as unverified.
- "The platform produced no crossing" (`noPlatformEvent`) and "the panel could
  not be placed under the pointer" (`preconditionUnmet`) are reported as
  **UNVERIFIED**, in their own column, never folded into the pass count.
- The behaviour a missing event might otherwise excuse — a notch left open with
  the pointer elsewhere — is asserted **deterministically**, on the real
  controller-owned notch with an injected pointer, and does gate the release.

Every hover result prints its provenance:

```
probe: enters=1 exits=0 handled=1 (of which containment=0) opened-by: trackingArea
```

Writing that line found three bugs in the instrumentation itself — a reset that
zeroed the very crossing it was measuring, a forwarding site that never recorded,
and counters that could not distinguish "the pointer arrived" from "the notch
resized under a still pointer". Each produced a *passing* check whose provenance
contradicted it. It also found two assertions that were simply wrong about the
design, the larger being a demand that the catcher close an open notch when it
deliberately hands over to the expanded panel instead.

### Still requires a human

See **docs/MANUAL_CHECKS.md**. Chiefly: the Finder drag gesture itself, dragging
items back out, hover on the external display, and the "notch stays open while
typing" guard. These need synthesised pointer input, i.e. Accessibility, which
LocalNook deliberately does not require.

## What must be repeated if anything changes

Not every change invalidates every result. This says which.

| If you change… | Repeat |
|---|---|
| **Anything at all** | The deterministic suite against the rebuilt binary, and record its new SHA-256. Every result below is about one hash. |
| `NotchHitPanel`, `HoverTracker`, `HoverProbe`, or `NotchViewModel`'s open/close scheduling | The full integration batch. These are the only files the live crossing path runs through, and the probe's own accuracy depends on them. |
| `NotchWindowController` lifecycle (`start`, `stop`, `rebuildPanels`, `teardownPanels`, the pointer safety net) | `testControllerTeardown` and `testMissedCrossingRecovery` — and re-check that `residue` still enumerates everything the new code holds. A leak the struct does not name cannot be caught. |
| The set of interaction kinds, or where claims are taken and released | `testInteractionOwnership` and `testControllerTeardown`. A new claim kind needs its own release path asserted; `retire()` covers the general case but a claim taken outside a `NotchViewModel` would not be. |
| `scripts/install.sh` | `scripts/test-install.py` in full. It runs only in disposable directories, so there is no reason to run a subset. |
| `scripts/build-release.sh` | `scripts/test-release.py`, and check that its fixtures still stub every script the release script now calls. Adding a call without adding the stub makes the fixtures test the wrong thing. |
| Display handling, `NotchGeometry`, or `connectedScreens` | The deterministic suite **and** a physical hot-plug. The seam covers the logic; it does not cover the window server. |
| The bundle layout, `Info.plist`, or signing | A full `build-release.sh`, then `install.sh` into a disposable target before `/Applications`. |

Anything requiring a human is listed separately in **docs/MANUAL_CHECKS.md** and
is not re-derivable from an automated run.

## Known gaps in coverage

- **Hover with a real pointer** cannot be automated: synthesising pointer
  movement requires Accessibility, which LocalNook deliberately does not need
  and which is not granted here. Hover on the **built-in** display was observed
  live in an earlier pass (seven open→close pairs against the running app);
  hover on an **external** display has not been observed and remains
  unverified. The automated substitute — moving a window under a still pointer
  — exercises the same code but is not the same gesture, and AppKit does not
  always deliver the crossing for it.
- **External display behaviour has not been seen on screen in this pass.** The
  monitor attached to this Mac (G274QPF E2, 2560×1440) is powered off, so
  `CGGetOnlineDisplayList` reports **one display**; every window count in this
  document says how many were connected when it was taken. The geometry paths
  are covered through `DisplayMetrics` and the attach/remove paths through the
  injected `connectedScreens` seam, but neither is a substitute for a physical
  hot-plug, and multi-display interaction scoping is verified against a notch
  seeded into the controller's registry rather than a second monitor.
- **Sleep/wake** handling is implemented and wired to `NSWorkspace.didWake`, but
  has not been exercised through a real sleep cycle.
- **Permission-denied paths** are asserted structurally rather than by actually
  revoking each permission.
