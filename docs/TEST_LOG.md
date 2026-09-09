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
| Release | Gates packaging | **Gates packaging on defects** |

### The release policy

"Integration checks never gate" was the wrong rule: it meant a demonstrated
product defect could ship because of which half of the suite happened to find
it. "Everything gates" is equally wrong: it reddens the build when the window
server declines to deliver an event, which teaches people to ignore the gate.

So the outcome has three states, and the exit code carries the distinction:

| Exit | Meaning | Release |
|---|---|---|
| `0` | Everything asserted and held | proceeds |
| `1` | A check **failed** — a delivered event was mishandled, or a final state was wrong. A demonstrated product defect. | **blocked**, from either half |
| `2` | Nothing failed, but a scenario could not be exercised: a missing environmental precondition, or input the harness could not deliver | proceeds, recorded as an explicit limitation |

Two consequences worth stating plainly:

- **A failure in the integration half blocks the release.** It is not advisory.
  `scripts/test-release.py` proves this with the `integration_defect` scenario.
- **An unverified scenario does not block, and does not disappear.** The build
  prints `NOTE: this build has unverified scenarios … It is not fully verified`,
  the names are listed at the end of the run, and `verify-candidate.sh` exits 2.
  The `integration_unverified` scenario proves it still packages.

In the deterministic half, exit `2` is itself treated as a failure: every check
there injects its own preconditions, so "could not run" means a seam has been
lost, not that the machine was busy.

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
| Sessions | Scan completes; ids are file paths. A **bounded** peek inside recent transcripts extracts four short strings — model, effort, chat title, current step — each truncated, none persisted. See "What the sessions widget reads" below. |
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

### What the integration half gates on

The live integration half moves a window under a stationary pointer, because
that is the only way to simulate hover without Accessibility, and AppKit does
not always deliver the crossing. It gates on defects and not on the environment
— see "The release policy" above.

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

## Current candidate — 2026-09-08

| | |
|---|---|
| Shipped binary | `64e8b294d41b862fb51d1879261226a3c8815011f340cb7dc4f4460686879897` |
| Disk image | `5c69c2e3253fbdb17e42c284bf2f7ee982f864a3dbb92bb9b2a29f83c9de2bea` |
| Source commit | `3470e4d79487185509d556416405988138fff2fc` |
| **Displays connected** | **2** (built-in + G274QPF E2) |
| Batch | 10 deterministic + 12 integration, fixed before the first run |

```
deterministic: 10/10 clean, 0 unverified, 0 defects   (265 checks per run)
integration:    0/12 clean, 12 unverified, 0 defects
VERDICT: no defects; some scenarios could not be exercised.   (exit 2)
```

Every integration run reported the same reason, and the suite names it itself:

```
probe: enters=0 exits=0 handled=0 (of which containment=0) idle=898s SCREEN-LOCKED
? [integration] hovering the notch opens it — UNVERIFIED: the screen is locked;
  loginwindow is above every window, so no crossing can reach the panel
```

**This candidate is explicitly not fully verified.** Six hover checks could not
be exercised because the screen was locked for the whole batch. Zero defects, in
either half. The hands-on checklist (docs/ACCEPTANCE.md) is what closes the gap.

### Installation

```
candidate  64e8b294…
installed  64e8b294…   /Applications/LocalNook.app
running    64e8b294…   pid 5439, executable resolved via lsof … txt
```

No staging or backup directory left in `/Applications`. Window layout with both
displays awake: 4 windows, one panel and one catcher per display, all at y=0.

### A note on measuring anything while the screen is locked

Two separate symptoms in this pass were artefacts of the machine being locked or
asleep, and both initially read as defects:

- **Hover crossings not delivered.** `loginwindow` covers everything; a
  background app receives none. See BUGS.md.
- **Panels at y=49/y=72 instead of y=0**, narrower and shorter. `caffeinate -u`
  woke the displays and the geometry returned to y=0, w=445/209, h=35 on both.
  Nothing was wrong with the app.

Neither is visible from the numbers alone. Any window-geometry or hover figure
recorded while the screen is locked describes the lock screen, not LocalNook.

## Superseded candidate — 2026-09-08 (1 display)

One binary, one batch, every run reported.

| | |
|---|---|
| Shipped binary | `9df4dce2d9376a8ad7e5e311573ef49b3e693a730cb8e1cff578b57743aed6f2` |
| Disk image | `d82f1c3afc1ef7e8247eba0196c20a508d99c0892cb5a901ae8d4ed3d631881d` |
| Source commit | `d51252b22b641f93da87d956220ec1dd967aa2f9` (`CFBundleVersion` 34) |
| **Displays connected** | **1** (built-in only; the G274QPF E2 is powered off) |
| Batch | 10 deterministic + 12 integration, fixed in `verify-candidate.sh` before the first run |

```
deterministic: 10/10 clean   (261 passed, 0 failed, 0 unverified — every run)
integration:   12/12 clean   (10 passed, 0 failed, 0 unverified — every run)
VERDICT: every run clean.
```

Every integration run reported the same provenance:

```
probe: enters=1 exits=0 handled=1 (of which containment=0) opened-by: trackingArea
```

One crossing delivered, one forwarded, opened by the tracking area — twice per
run, once for the panel and once for the catcher. `exits=0` is expected: the
panel is moved away rather than the pointer, and the catcher hands an open notch
to the panel rather than closing it.

### What this does and does not establish

- **Does:** this exact binary passed 22 consecutive runs with nothing unverified,
  and the installed copy is byte-identical to it.
- **Does not:** prove the intermittent missed crossing is gone. It did not recur
  in 12 runs, but the earlier ~1-in-12 figure was measured on a different binary
  and included an assertion that was itself wrong (see BUGS.md § the catcher
  hand-over). Twelve clean runs lower the estimate; they do not retire the
  entry, which stays OPEN.
- **Does not:** cover hover with a real pointer on an external display. That
  check could not be run at all and is recorded as unverified in
  docs/MANUAL_CHECKS.md, not folded into the numbers above.

### Installation

```
before:  5ed4846d…  pid 85075, started 14:46:09
after:   9df4dce2…  pid 95069, started 16:25:09
```

Verified afterwards: the installed binary's hash equals the candidate's; the
running process's own executable (via `lsof … txt`) hashes to the same value;
the process is newer than the install; and no staging or backup directory was
left in `/Applications`.

This section is written after the run it describes, so it is necessarily a
commit later than the candidate's own `LocalNookCommit`. The binary is
identified by its hash, not by `HEAD`.

## Current candidate — 2026-09-08

| | |
|---|---|
| Shipped binary | `107f25874b7d89b344c88f44cbe9e48243150889a4ad027f3b0d3dbc890001dc` |
| Disk image | `4b42282227951a7bed966f7a2614967ec17d83ed12260a4473fee18b41182287` |
| Source commit | `8199f60b75c8e1084c480b19c5b78a8ec0d24555` |
| **Displays connected** | **2** (built-in + G274QPF E2) |

```
deterministic: 10/10 clean, 0 unverified, 0 defects   (324 checks per run)
integration:   12/12 clean, 0 unverified, 0 defects
VERDICT: every run clean, nothing unverified.
```

Plus, against that same binary: installer failure paths 36/36, self-test
isolation 23/23 across completion / SIGTERM / SIGKILL, release gates 6/6.

Every integration run reported a delivered crossing:
`enters=1 handled=1 (containment=0) opened-by: trackingArea`. One run showed
`enters=3` — the harness retrying its stimulus, which is what the retry loop is
for; the forwarded count stayed at 1, so nothing was double-handled.

### An unexplained count, stated rather than smoothed over

Six runs on a debug build shortly before this candidate reported **326** checks;
the candidate and a fresh rebuild of its exact source both report **324**, with
an identical set of check *names*. So two checks ran twice, or ran at all, under
a runtime state that no longer reproduces. Nothing failed in either case, and
the current figure is stable across thirteen runs — but the discrepancy is not
accounted for, and is recorded here rather than rounded away.

## Current candidate — 2026-09-09

| | |
|---|---|
| Shipped binary | `b00478e36f7769a703c2b1fe8bc61fd1e3e33addbfeb9a6081229e751b3e5005` |
| Disk image | `a9e243e71836c8a3d18ff148555588952fede1f6a3075a78bc1017331816dd30` |
| Source commit | `4a6b23c33a4eaa972f50ec10299f3e220c3328d6` |
| **Displays connected** | **1** (built-in only; the external monitor is powered off) |

```
deterministic: 10/10 clean, 0 unverified, 0 defects   (456 checks per run)
integration:   12/12 clean, 0 unverified, 0 defects
VERDICT: every run clean, nothing unverified.
```

Plus, against that same binary: installer failure paths 36/36, self-test
isolation 23/23 across completion / SIGTERM / SIGKILL, release gates 6/6
(5 blocking scenarios blocked, 1 non-blocking scenario allowed).

Every integration run reported a delivered crossing:
`enters=1 handled=1 (containment=0) opened-by: trackingArea`. Run 1 showed
`exits=1` after the notch had already opened, which is the pointer leaving
afterwards and does not affect the assertion.

**"All automated checks passed" is not "feature acceptance complete."** The
browser-media feature's remaining acceptance is listed under *What has and has
not been observed* above: no playback has been observed, page access has never
been enabled, and Safari has never been running. Those are unverified, not
passed.

### Two release gates fired during this pass, and both were the harness

Recorded because a gate that cries wolf is worse than no gate. Both are written
up in full below. Neither was a product defect; both were checks reading the
machine's state instead of establishing it, and both are now fixed at the seam
rather than by loosening the assertion.

`scripts/build-release.sh` also exited non-zero twice with its output
suppressed, and did not reproduce in five subsequent runs, three of them with
output captured. Unexplained. It failed closed — no artifact was produced — so
nothing shipped on the strength of it.

## A deterministic check that was not — 2026-09-09

The frozen batch for this pass failed on run 2 of 10:

```
✗ typing in Notes pins the notch being typed in
```

and the gate did what it is for: *"a demonstrated defect. This candidate must
not ship."* The other nine runs, and every earlier batch, were clean.

The cause was not the product. A `.textEditing` claim survives exactly as long
as its display's panel holds key focus:

```swift
if !(panels[id]?.isKeyWindow ?? false) { model.releaseInteractions(of: .textEditing) }
```

The check claimed text editing, ran the pointer-safety pass, and asserted the
notch stayed open — which requires the panel to be key. Nothing in the check
made it key. It was reading whatever the window server happened to be doing,
so it was really asserting that nothing else on the Mac had taken focus in the
preceding moment. About once in ten runs, something had.

Worse, a second check twenty lines earlier asserts the *opposite* — that a
claim is dropped when the panel is not key — and it too was reading the ambient
state. Two checks with contradictory requirements, both passing by luck.

Key focus is now injected, like pointer position, button state, display
configuration and scheduling before it: `panelHoldsKeyFocus` defaults to nil,
meaning "ask the window", and each check supplies the answer its rule needs.
A third check asserts the seam is nil unless a test set it, so production
cannot be left stubbed. The suite gained one real assertion — that a claim
*survives* while its premise holds — which nothing had covered.

The same pass removed a wall-clock assertion for the same reason: a check
asserting that 500 consent reads finish inside 100 ms was a stopwatch standing
in for "the cache works". It failed the installer's gate once and passed on
every rerun. Counting system calls says the same thing and cannot flake.

### The same mistake in the live half

The rerun then failed two of twelve integration runs:

```
✗ [integration] hovering the catcher opens the notch
  — LocalNook handled 4 crossing(s) but the notch is closed
  probe: enters=2 exits=2 handled=4 idle=0s
```

The counters answer it. The stimulus is a window moved under a **still**
pointer; `exits=2` says the pointer did not stay still, and `idle=0s` says
somebody was using the Mac. The notch closed because it was told the pointer
had left. Failing that is blaming the app for obeying the last thing it was
told — and the eight clean runs in the same batch show `idle=3s` upward.

`HoverProbe.classify` now reports a delivered exit during the entry check as a
**missing precondition**, which is unverified and does not block, rather than
a mishandled event, which is a defect and does. A crossing the app never
handled is still a defect, exit or no exit. The classifier is pure, so all
seven branches are now asserted deterministically, over counters recorded
through the probe's own API — no pointer, no window, no window server.

**The rule this leaves behind:** in the deterministic half, if a check depends
on a condition, it must establish that condition. A check that reads the
machine's mood reports the machine's mood, and reports it as a product defect.

## What must be repeated if anything changes

Not every change invalidates every result. This says which.

| If you change… | Repeat |
|---|---|
| **The number of attached displays** | The whole deterministic suite. Two checks passed for a year on one display and failed intermittently the moment a second was attached, because they took `allModels.first` — an arbitrary dictionary entry — while `perform(.open)` routes to the pointer's display. Display count is a test input, not background. |
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

## What the sessions widget reads

**Off by default.** `Settings → Widgets → AI session labels` offers two modes,
and the shipped default is **Metadata only**, in which no transcript body is
opened at all. Switching the AI Sessions widget on is *not* consent to read
inside transcripts; that is a separate, explicit choice under its own
preference key, so an existing choice is never overwritten by an update.

| Mode | What is read |
|---|---|
| **Metadata only** (default) | File name, size, modification date. No transcript content. |
| **Read labels from session files** | The four fields below, and nothing else. |

| Field | Example | Source, exactly |
|---|---|---|
| model | `Opus 5` | `message.model`, mapped through an identifier table; free text in that field is refused |
| effort | `max` | the same record's `effort` |
| chat title | `LocalNook foundation audit` | a `custom-title` record's `customTitle` |
| current step | `Running the test suite` | the newest assistant record's `tool_use.input.description`, else its tool `name` |

### The rules, and why each exists

- **Strict extraction.** There is no fallback to assistant prose or user input.
  If the named field is absent the value is absent. A test asserts that a
  transcript whose only content is a message body yields nothing at all.
- **One turn.** Model, effort and step all come from the *same* assistant
  record, so they cannot be assembled from different turns into a sentence that
  was never true.
- **Freshness is authoritative.** Activity comes from the record's own
  timestamp, not the file's modification date — a file can be touched by a
  backup or a search index without the session doing anything. A step older
  than 120 seconds is dropped rather than shown, and the marching indicator
  stops. No timestamp means `unknown`, which also stops it.
- **Never persisted, never printed.** Not logged, not in diagnostics, not in
  `--render-preview` output. The only cache is in memory, keyed on path + size +
  modification date so an unchanged file is not reopened, and it is cleared the
  moment the feature is switched off — along with the labels already on screen.
- **Not on the lock screen.** While locked, the reader declines to read at all
  and the widget falls back to metadata-only.

### The bounds are a real limitation, not a formality

At most a **256 KB tail**, plus a **512 KB head** only when the title has not
already been seen. Transcripts here reach **40 MB**, and at most **six**
sessions are opened per scan, only those touched within the hour.

That is a *sample*, and it can miss:

- A title set unusually late — past the head window, before the tail window —
  is not found, and the session shows its directory name. Reported as an absent
  title, never filled in with a guess.
- A session whose last 256 KB holds no assistant record yields no step.
- Head and tail can come from far apart in one conversation. Nothing is inferred
  across that gap.

Forty-eight assertions cover the extraction, the freshness rule, every bound,
and the malformed cases: half-written trailing records, unparseable lines,
unknown schemas, missing fields, future timestamps, multi-line and control
characters, and sensitive-looking strings that must not escape. All of them run
against fixtures the test writes; the user's own transcripts are never opened.

## Browser media: what is possible, measured

Every claim here was checked on this machine rather than inferred, and each is
labelled with how it was established.

### MediaRemote is not a path *for this app, here*

The private framework that would give a system-wide now-playing feed has been
entitlement-gated since macOS 15.4. Probed from inside the LocalNook bundle on
macOS 27.0:

```
framework present: true
dlopen: ok
symbol: found
callback: returned
payload: nil          ← while QuickTime was confirmed playing
```

`nil` with nothing playing would be ambiguous, so the probe was repeated with
audio confirmed via AppleScript. It stays nil.

**Scope.** One app without the entitlement, one machine, one OS version. That
is consistent with Apple's documented gating, but a single nil is not evidence
that no configuration anywhere gets an answer. The claim being made is only
that LocalNook cannot rely on it. No MediaRemote code ships. The published
workarounds — a bundled Perl helper that inherits Apple's own bundle
identifier, or code injection with SIP disabled — are a helper installation and
a security bypass, and are out of scope.

### Tier 1 cannot say which tab is playing — structurally

This was the central correction of this pass. Combining a tab title with the
browser's audio output does **not** establish that the named tab is playing.
Two independent facts, both read rather than assumed:

**Neither browser publishes per-tab audio.** Straight out of their `.sdef`
files:

| Browser | `tab` properties |
|---|---|
| Chrome | `id`, `title`, `URL`, `loading` |
| Safari | `source`, `URL`, `index`, `text`, `visible`, `name` |

There is no `audible`, `playing` or `muted` property to ask for.

**CoreAudio attributes output per process, and Chrome mixes every tab through
one.** Of Chrome's 20 running processes on this machine there is exactly one
`--utility-sub-type=audio.mojom.AudioService`. Per-tab attribution is not
merely unimplemented; it is not expressible through this mechanism.

So Tier 1 reports **"Browser audio active"** with the tab's playback state
marked `.unknown`, never "Playing". With one player tab open it still names the
tab; with several it names the browser and the count instead, because naming
one of them would be a coin toss. `BrowserPlaybackResolver` holds that decision
as a pure function, so every case is decided in one place and tested there.

### What each tier can do

| | Tier 1 — consent only | Tier 2 — plus the browser's own toggle |
|---|---|---|
| Mechanism | Scripting dictionary (title, URL) + public CoreAudio (is the *browser* emitting audio) | `execute javascript` reaching each page's media element |
| Title and source | yes | yes |
| Which tab is playing | **no** | yes |
| Playing / paused | **no** — "Browser audio active", state unknown | yes, authoritative (muted and ended included) |
| Position, duration | no | yes |
| Play/pause, seek | no | yes, on the identified tab |
| Artwork | no — deferred, see below | no — deferred, see below |

**Artwork is deferred, not impossible.** An earlier note said a browser cannot
supply artwork without a third-party request; that was an overstatement. A page
has plausible local sources — a `<video>` poster, `navigator.mediaSession`
metadata — reachable through page access. None has been verified here, and most
hand back a URL, which would mean a network request this app does not make. No
network fetching was added in this pass.

### Consent is read, not provoked

`AutomationPermission` wraps `AEDeterminePermissionToAutomateTarget`, public
since 10.14. With `askUserIfNeeded: false` it answers from the system's records
without sending an event and without a dialog — verified: it returned
immediately for a running target and raised nothing, and returned `-600` for
every target that was not running.

This replaced a claim in `Permissions.swift` that no read-only API existed and
that consent could only be discovered by sending an event and watching it fail.
That approach conflates refusal with never having asked, and makes discovery
itself a thing that can raise a prompt.

| OSStatus | Meaning |
|---|---|
| `0` | granted |
| `-1743` | refused |
| `-1744` | never asked — no System Settings entry yet |
| `-600` / `-609` | target not running; says nothing about consent |

**Cost: 12.6 ms per call**, measured over 200 calls — an XPC round trip to
`tccd`, not a lookup. Both media views ask about both browsers while building
their bodies, so answers are cached and the self-test asserts that 500 reads
make at most one system call.

### The probe reports its own attribution now

Run from a shell, `--media-probe` reported Chrome as **Connected** while the
running app's dashboard said **"Google Chrome isn't connected"**. The dashboard
was right. Consent is granted to a *client*, and macOS attributes a process
launched from a terminal to that terminal, so the probe was answering for the
shell under LocalNook's name. It now prints its parent process and says so.
**The authoritative answer is the one the running app shows.**

### Two things measurement caught that reasoning would not

**`tab` inside a `tell application` block is the browser's tab class.** The tab
listing script separated fields with the `tab` constant. Inside `tell
application "Google Chrome"` that resolves to Chrome's `tab` *class*, and
concatenating it yields the literal text `"tab"` — so every line came back as
one field instead of three and the provider reported **no media tabs while a
player sat open**. Nothing errored; the symptom was an empty widget, which is
also what "nothing is playing" looks like. `character id 9` is the term neither
dictionary redefines, and a check asserts the generated source keeps using it.
Found only by running against a real browser.

**Chromium plays audio from helper processes.** With a video playing:
`Google Chrome Helper outputting=YES`, `Google Chrome outputting=no`.
Attributing by process name concludes the browser is silent while it plays.

**Chrome runs under App Translocation.** Its helpers live at
`/private/var/folders/…/AppTranslocation/<uuid>/d/Google Chrome.app/…` while
`NSWorkspace` reports the bundle at `/Applications/Google Chrome.app`. Matching
the installed path found 0 of 30 helpers; matching
`NSRunningApplication.bundleURL` finds 30 of 30.

### What has and has not been observed

Observed live, this pass, with **no audio played** — test tabs were created on
sites that do not autoplay (a SoundCloud track page, a Vimeo video page), and
`browserAudio=false` was confirmed at every step:

| Observation | Result |
|---|---|
| No player tab open | `mediaTabs=0`, resolved to nothing |
| One player tab, silent | `mediaTabs=1`, **resolved to nothing** — a media tab with no audio produces no claim |
| Two player tabs, silent | `mediaTabs=2`, resolved to nothing |
| Page access detection | `execute javascript` returns Chrome error `12` per tab; recorded as page access unavailable, not as "no media element" |
| The app's own consent state | dashboard shows "Google Chrome isn't connected" with a Connect action |

Test tabs were closed afterwards; a check confirmed none remained.

| Source | Observed | Result |
|---|---|---|
| Chrome, tab listing and selection | yes | Correct after the `tab`-class fix |
| Chrome, actual playback | **no** | Requires audible sound; deferred to the user |
| Tier 2 page access | **no** | The browser toggle is off and must not be set by this app |
| Safari | **no** | Never running during testing |
| Music, Spotify | **no** | Music not running; Spotify not installed |
| Populated widget on screen | **rendered, not observed** | Three states rendered offscreen at 720 pt and 520 pt; a live populated widget needs playback and consent |

Synthetic coverage — **119 assertions**, fixtures only, no browser, no audio,
no permission — is separate and stands in for none of the above. It covers URL
matching, title cleaning, page-reply parsing, the audio debounce, capability
gating, source ranking and stickiness across twelve polls, and the full
resolution matrix: two tabs with one playing, an unrelated tab making noise, a
paused video while another plays, muted playback, buffering, ended media, page
access that reached only some tabs, and the selected tab closing.

## Self-test isolation

The suite runs against a **disposable preferences domain and a disposable
support directory**, chosen from the command line before any singleton can
observe them (`AppInfo.isSelfTest`). Production is not touched and therefore
does not need restoring.

An earlier version snapshotted the production domain and restored it via
`atexit`. That was removed: it was unnecessary, since `@Pref` already wrote to
the disposable suite, and unsafe, since restoring a snapshot would overwrite
whatever the running app changed meanwhile — and `atexit` does not run on a
crash or a `SIGKILL` anyway.

`scripts/test-isolation.py` proves the property rather than the restore. It
writes a sentinel into the production domain and into the production support
directory, then samples both **while the suite is still running** and again
afterwards, across three endings:

| Ending | Result |
|---|---|
| Completion | 25 samples during the run, all unchanged |
| `SIGTERM` part-way through | unchanged during and after |
| `SIGKILL` part-way through | unchanged during and after |

Twenty-three assertions. The only cleanup it performs is removing the
disposable directories and disposable domains a killed run could not remove
itself.

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
