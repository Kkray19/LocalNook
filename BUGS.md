# LocalNook — known bugs

Recorded during development. Each entry says how it was observed, so it can be
reproduced rather than taken on trust.

---

## OPEN

### Hover on an unlocked screen is under-measured, not proven

Not a known defect — an evidence gap. Every `enters=0` observation has a
sufficient explanation that is not about LocalNook (see "Hover: resolved into
three separate things" under RESOLVED), and no run has ever produced
`eventDropped` or `wrongState`, the two outcomes that would be defects and that
both fail the build.

But the clean-run evidence and the failing-run evidence come from different
machine states, so "hover works" rests on runs taken before the screen locked
plus one live observation session on the built-in display. Hover with a real
pointer on the **external** display has still never been observed at all.

**Closes when:** docs/ACCEPTANCE.md steps 1, 9 and 13 come back with observed
results.

### Multi-display scoping is verified against a seeded notch, not two monitors

The rule that an interaction pins only its own nook is exercised on a
single-display Mac by seeding a second notch into the controller's registry
(`installSyntheticNotch`), so the real `closeIfPointerHasLeft` and claim
validator run over two models. This replaced a check that asserted `true` when
only one display was attached — a reported pass for something that never ran.

It is a fair test of the rule and a weaker test of the hardware path: display
attach/remove still goes through the injected `connectedScreens` seam rather
than a physical hot-plug. The last verification with a second monitor physically
attached is recorded in docs/TEST_LOG.md; the checks in this session were run
with **one display connected**.

### Finder drag-and-drop has not been performed end to end

**What is verified:** `ShelfStore.ingest(_:)` is exercised against a real
`NSPasteboard` carrying real file URLs — the same content Finder writes for a
drag — covering multi-file drops, folders, duplicates, long names, deleted and
renamed files, selection, text with no file of its own, and unsupported content.
See the "Tray (real files)" section of `--self-test`.

Multi-item handoff adds the "Tray handoff" section: the whole selection
arithmetic (plain, command and shift clicks, anchor movement, removal), and the
payload a drag would carry (tray order, deduplication, folders, links, missing
files excluded, exclusion wording).

**What is not:** any actual drag *gesture* — from Finder into the panel, a
single row back out, or the new multi-file handle out to another app. All need
synthesised pointer input, which requires Accessibility. The payload is
asserted; the gesture that carries it is not. A pasteboard assembled in a test
is not evidence that Finder accepted a drop.

The originals guarantee is now asserted byte for byte: fixtures with real
content (non-text bytes, multi-byte UTF-8, a file inside the folder) are
fingerprinted by exact bytes, size and modification date before the removals and
compared whole afterwards, with a companion check that fails if the fixtures were
empty.

Candidate `be9ee72` is installed; none of the physical checks below were
performed in that session.

**Manual check:** see docs/MANUAL_CHECKS.md §1b.

---

## RESOLVED

### Idle CPU: 12.6% of a core while collapsed and doing nothing

**Reported:** Activity Monitor showed LocalNook near the top of the list on an
otherwise idle Mac. Confirmed by differencing the process's cumulative CPU time
over 5-second intervals rather than reading `ps`'s lifetime average: **median
12.6%, range 9.6–14.2%, over 60s, collapsed**.

**How it was attributed:** `/usr/bin/sample` on the installed app put every
sample on the main thread inside
`CATransaction::flush -> NSDisplayCycleFlush -> NSWindow layoutIfNeeded ->
NSHostingView.layout() -> DisplayList.ViewUpdater`, with **no LocalNook frame
anywhere on the stack**. The app was not computing anything; it was re-laying
out the whole panel on every display-link tick.

Bisected on one frozen release build with an environment switch compiled in,
each variant run against a canary so that a machine-wide render stall could not
be mistaken for an improvement:

| Variant | Median CPU | Canary |
|---|---|---|
| control | 6.7% | 11.2% |
| busy spinner not animating | **0.4%** | 13.6% |
| control | 4.1% | 11.2% |
| busy spinner not animating | **0.4%** | — (stalled, discarded) |

**Cause:** SwiftUI's `.repeatForever` never becomes quiescent. The view graph
reports pending work every display-link tick for as long as such an animation is
on screen, and the cost is the pass over the view tree, not the pixels — so an
11pt spinner costs a full panel relayout at 120Hz. `BusyIndicator` (beside the
collapsed notch, shown whenever any agent is working) and `SessionWorkingBar`
both used it.

**Fix:** both indicators are drawn by Core Animation instead. An animation added
to a layer is handed to the window server once and interpolated there; the app
sleeps through every frame, and the render server stops on its own when the
window is occluded or the display sleeps. See
`Sources/LocalNook/UI/RenderServerAnimation.swift`.

**Verification:** the "Animation lifecycle" section of `--self-test` asserts
attachment and never progress — installed in a window, removed when the view
leaves it, absent under Reduce Motion, not restarted by a redundant update — so
a busy Mac cannot make it flaky.

**Measured after the fix (2026-09-14).** Candidate `be9ee72`, executable SHA-256
`a27485653346cc5ba7aee35954f01644ba2cbd4317d97945a1189381029fc935`, installed
through `scripts/install.sh`. One display, screen unlocked. CPU from differenced
cumulative CPU time, 5-second intervals.

| Scenario | Before (`62370ff`) | After (`be9ee72`) |
|---|---|---|
| Installed app, collapsed, an agent working (spinner visible in a screenshot), 60s | median **14.4%**, range 13.2–16.7% | median **0.4%**, range 0.4–0.8% |
| Isolated default-preference instance, collapsed, round 1 of 2 (30s each) | 7.3% (6.4–9.6%) | 0.4% (0.2–0.6%) |
| Isolated default-preference instance, collapsed, round 2 of 2 | 9.4% (8.2–9.8%) | 0.3% (0.0–3.4%) |
| Screen locked (measured 2026-09-11) | 0.4% | not measured |

The isolated rounds were interleaved old, new, old, new, with the installed new
build measured alongside as a second process (0.3–0.7% throughout). The old
build burning 7–9% in rounds 1 and 3 is itself the proof that compositing was
live around the new build's rounds, so the new build's low readings are not a
locked-screen artefact.

**Not measured, and why:**

- *Expanded and idle* — attempted by warping the pointer onto the notch. The
  panel opened, showing the Dashboard with an agent's working bar and "No media
  app running", and read 0.6–1.6% for the first ~25s. Someone then used the Mac,
  the pointer moved and the notch closed, so the 60-second run is **invalid** and
  recorded only as a partial reading. No "before" exists for this state on this
  configuration.
- *Media monitoring on, nothing playing* — covered only by that partial expanded
  reading and by the collapsed readings, which ran with the installed
  configuration's media monitoring as set.
- *Collapsed with no live activity* — not isolatable while an agent session is
  running the measurement itself; the busy-spinner readings above are the
  heavier case.
- *Two displays, and locked/asleep on the new build* — only one display was
  attached, and the screen was not locked during this session.

**Two measuring traps, recorded because both produced confident wrong answers:**

1. **A locked screen or a slept display reads as 0% for everything.** macOS stops
   compositing, so the runaway animation costs nothing and every variant looks
   fixed. One bisect round returned "everything is 0.4%" including the control.
   Always measure a canary process in the same window.
2. **`-key value` launch arguments do not override these preferences.**
   `@Pref` reads `object(forKey:) as? Bool`, and `NSArgumentDomain` stores the
   value as an `NSTaggedPointerString`, so the cast fails and the default is
   used. An entire pref-based bisect ran with every setting at its default and
   was discarded. Verified directly with a three-line program before relying on
   any of it.

### The published app carried the builder's account name

**Observed:** preparing the public v0.1.0 download, a search of the built bundle
found the builder's home directory in the executable. `nm -pa` showed 82 `OSO`
entries — the linker's debug map, one absolute path per object file under
`~/Developer/LocalNook/.build/`. The source tree and the whole git history were
clean; only the compiled artefact leaked it.

**Consequence:** every download names the account that built it. The v0.1.0
asset was hand-cleaned (`strip -S`, ad-hoc re-sign, re-verified: 758 checks,
signature valid, zero occurrences) before upload, and the published zip was
re-downloaded and matched by SHA-256.

**Fix:** `scripts/build-release.sh` strips debugging symbols while assembling the
bundle (`strip -S` keeps the symbol table, so crash reports still name
functions) and then refuses to publish if `$HOME/` appears anywhere in the
bundle. Matching `$HOME` rather than a name keeps any account name out of the
repository.

**Verification:** `scripts/test-release.py` adds a blocking `home_path` scenario —
a fixture that passes every test but carries a home-directory path — and asserts
the release stops with `BUILD-MACHINE PATH IN BUNDLE`. The real candidate build
printed "no build-machine paths", and `grep` over the candidate app and the app
inside its DMG found none.

### Hover: resolved into three separate things, none of them open

**Reclassified, then closed.** The single entry that used to sit here —
"roughly 1 run in 12 misses a hover crossing" — was three different things
wearing one number, and none of the three is a product defect. What remains is
not an open bug but an **under-measured case**: hover on an unlocked screen with
a real pointer, which is what docs/ACCEPTANCE.md steps 1, 9 and 13 ask for.

| Part | Verdict |
|---|---|
| An assertion the catcher was never meant to satisfy | closed — the test was wrong |
| Instrumentation that misreported its own counters | closed — three bugs, fixed |
| `enters=0` runs | closed — the screen was locked |

#### 1. Invalid assertion — CLOSED, was never a product failure

The reproducible failure (4 runs of 4) was the catcher being asked to close an
open notch. It deliberately does not: once the notch is open the pointer has
moved *into* the expanded panel, which owns hover from then on. The test was
wrong. Corrected; see "the catcher was asked to close a notch it deliberately
hands over" under RESOLVED.

#### 2. Incomplete instrumentation — CLOSED, evidence was unreliable

Three probe bugs meant earlier classifications cannot be trusted at all: the
counters were reset *after* the stimulus, `HoverTracker` never recorded that it
forwarded anything, and containment re-checks were counted as crossings. Every
hover figure recorded before those fixes describes the instrument, not the app.
This is why the old ~1-in-12 number is not comparable to anything measured
since, in either direction.

#### 3. A locked screen — CLOSED, and it was never a platform gap either

**What it actually was.** With the screen locked, `loginwindow` covers every
display above all other windows and a background app is sent no tracking-area
crossings at all. The harness cannot deliver its input. That is a missing
precondition, not a platform quirk and not a defect.

**Two wrong answers were held first, and both are worth recording.**

*Wrong answer one: "roughly 1 run in 12, intermittent."* It is not intermittent.
A twelve-run batch went eight clean then four with `enters=0`; the next twelve
were all `enters=0`. Sticky, not random. The rate was an artefact of averaging
across a state change nobody had noticed.

*Wrong answer two: "it tracks machine idle time."* Idle time was the obvious
thing growing, and the correlation looked strong — clean below it, `enters=0`
above it, across more than twenty runs. It was still wrong. The test that killed
it: `caffeinate -u` wakes the display and resets the idle counter to single
digits, and the crossings **still** did not arrive. A correlation observed in
one direction across twenty runs was not evidence of a cause.

**What settled it.** Enumerating the windows under the pointer, rather than
reasoning about what might be true:

```
under pointer: Window Server  layer=2147483646  (0.0, 0.0, 1512.0, 982.0)
under pointer: loginwindow    layer=2004        (0.0, 0.0, 1512.0, 982.0)
```

`CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"] == 1` confirmed it
directly.

**How it is reported now.** The suite checks the lock state *before* attempting
the crossing-dependent assertions, because one of them is a negative — "a
pointer merely passing over the notch does not open it" — which a locked screen
satisfies for entirely the wrong reason. Reporting that as a pass would be worse
than reporting nothing:

```
? [integration] hovering the notch opens it — UNVERIFIED: the screen is locked;
  loginwindow is above every window, so no crossing can reach the panel
? a pointer merely passing over the notch does not open it — UNVERIFIED: the
  screen is locked, so nothing could have opened it anyway
```

The checks that do not need a crossing — `starts collapsed`, `open() opens`,
`toggle() collapses` — still run and still pass.

**What remains genuinely unknown.** Whether hover has *any* residual problem
when the screen is unlocked. Every `enters=0` observation now has a sufficient
explanation that is not about LocalNook, and no run has ever shown `eventDropped`
or `wrongState` — the two outcomes that would be defects. But the clean-run
evidence and the failing-run evidence come from different machine states, so the
honest position is that the unlocked case is **under-measured**, not proven good.

**What would establish it:** steps 1, 9 and 13 of docs/ACCEPTANCE.md — hover with
a real pointer on both displays, and one integration run on an unlocked screen.


### 0. Retiring a notch cancelled its work but never released its claims

**Found by:** the new `testControllerTeardown`, first run — `a removed display's
claims are released — claims survived: ["textEditing"]`.

**Cause:** `rebuildPanels()` retired a panel for a display that had gone away and
called `models[id]?.cancelPending()`, which cancels timers but leaves interaction
claims held. A claim is only released by whoever took it, and after retirement
nobody will.

**Why it matters beyond tests:** unplug a display while typing in Notes and the
retired model keeps a `.textEditing` claim forever. It is dropped from the
registry, but any view still holding it — and any code that later consults it —
sees a notch that reports itself as permanently interacting, which is precisely
the state the recovery fallback refuses to close.

**Fix:** `NotchViewModel.retire()` cancels pending work, releases every claim,
clears drag targeting and returns to `.closed`. Both teardown paths
(`rebuildPanels`'s retire loop and `teardownPanels`) use it.

### 0a. The catcher was asked to close a notch it deliberately hands over

**Found by:** the new exit-side attribution reporting `wrongState` — an exit that
AppKit delivered, that LocalNook forwarded, and after which the notch was still
open. Four runs out of four, which is what distinguished it from the
intermittent platform gap.

**Cause:** the assertion, not the app. Once the notch is open the pointer has
moved *into* the expanded panel; the catcher is behind it and its exit means
nothing. `makeHitPanel` says so explicitly: closing is the panel's job. Demanding
a collapse from the catcher asserted a behaviour the design does not have — and
would have hidden the contract that does matter.

**Fix:** the catcher now asserts the hand-over (the notch stays open) and that
leaving clears the stay-shut latch. Closing on exit stays a hard assertion in
`testHoverPath`, where it really is the panel's job.

### 0a2. Three instrumentation bugs, each producing a passing check whose provenance contradicted it

1. `HoverProbe.reset()` ran *after* the first placement, zeroing the crossing
   that opened the notch — a pass reporting `enters=0`.
2. `HoverTracker` forwarded crossings without recording that it had — a notch
   opened by the tracking area reporting `handled=0`.
3. Forwards caused by a tracking-area rebuild finding the pointer already inside
   were counted as crossings, so `handled` could exceed `enters` for reasons
   that had nothing to do with a pointer arriving.

**Why it matters:** a probe that lies is worse than no probe, because it is
believed. Each of these was visible only by reading the provenance line next to
a green check and noticing it could not be true.

**Fix:** reset before the stimulus; record at every forwarding site; count
containment forwards separately; and print the transition source, since stage
counters alone cannot say which mechanism moved the notch.

### 0b. Two checks passed because they had not run

**Found by:** reading the suite for `check(..., true)` with no computed condition.

1. "a claim on one display does not pin another" asserted `true` whenever fewer
   than two displays were attached — i.e. always, on a one-display Mac.
2. "the fallback holds off while the pointer is on the notch" asserted `true`
   whenever the tester's pointer happened not to be on the notch.

**Fix:** the first seeds a second notch into the controller's registry so the
real per-model rule is exercised; the second injects the pointer so both
branches run on every machine. Neither reports a pass for work not done.

### 0b2. The install script could not see a process launched through a wrapper

**Found by:** adding the scenario that was missing. Every earlier install test
had either an empty target or a bystander running from a different path, so the
"stop the running app" branch was skipped and reported nothing — the path about
to run against a live installation was the one path with no coverage.

**Cause:** `pgrep -f "^$TARGET_EXEC"`. Anchoring to the start of the command line
looked tighter and was wrong: a process launched through a wrapper has the
wrapper first, so the match failed and the script concluded nothing was running.
It then replaced the bundle out from under a live process while reporting a
clean install.

**Fix:** match the full executable path anywhere in the command line — no other
binary's argv contains it — and exclude this script and its parent explicitly,
since `--source` pointing at the target would otherwise make it a match for
itself. Two scenarios now cover it: a process that stops on `TERM`, and one that
ignores `TERM` and must be escalated past.

### 0c. The install script reported success after failing

**Found by:** `scripts/test-install.py`, on the first draft of `install.sh` —
"the app lands at the target" failed while "succeeds" passed.

**Cause:** two bugs at once. `trap 'rm -rf "$STAGED"' EXIT` made the trap's last
command the script's exit status, so a `set -e` abort exited 0. And
`step "Staging into $TARGET_DIR…"` let bash absorb the multibyte ellipsis into
the identifier, so `set -u` aborted with `TARGET_DIR…: unbound variable` —
locale-dependent, which is why it did not reproduce in a hand-run.

**Why it matters beyond tests:** an installer that exits 0 without installing is
the worst possible failure mode. It is exactly how a previous session left the
app uninstalled while reporting a completed release.

**Fix:** both traps preserve the status (`trap 'status=$?; …; exit $status'`),
every `$VAR` adjacent to non-ASCII text is braced, and the cleanup paths refuse
to `rm -rf` an empty variable.

### 0d. `stop()` left the recovery check running

**Found by:** a frozen 15-run of build 21 showing *scattered* failures across
unrelated sections — `perform(.open)` not opening, claims surviving a close,
attribution coming back nil. Individually each looked like a different bug; the
pattern was cross-contamination.

**Cause:** `stop()` cancelled the geometry and shrink tasks but not the
once-a-second recovery task. A stopped controller kept polling, still holding
references to its models, and could close a notch belonging to a later session.
An earlier edit adding this cancellation had been overwritten by a subsequent
restructure — the assertion that caught it at the time no longer covered the
rewritten code.

**Why it matters beyond tests:** "stop" that does not stop is a leak. It is
called on termination and whenever the controller is rebuilt.

**Fix:** `stop()` cancels it, with an assertion that a stopped controller is not
polling.

---

### 0. A window moving under a stationary pointer could miss the crossing — ATTEMPTED FIX REVERTED

**Observed:** roughly 1 failure in 15 runs —
`hovering the notch opens it — tracking area did not deliver mouseEntered`.

**Attempted fix (reverted):** observing `NSWindow.didMoveNotification` and
rechecking pointer containment. Measured on the shipped binary it made things
**far worse** — 1 clean run in 10, against roughly 14 in 15 before. Rechecking
introduced a second writer for `isInside` alongside the tracking area's own
"already inside" pass, and the two disagreed often enough to swallow real
crossings. A second attempt using screen-space coordinates and a deferred pass
did not help.

Reverted to tracking areas alone. The rare miss is the better trade, and the
lesson is recorded rather than the change: a fix for a 1-in-15 flake that is not
measured against the same binary can easily be a 9-in-10 regression.

**Status:** OPEN, at its original low rate. Only observed when a *window* moves
under a stationary pointer, which is how the tests drive hover; normal use moves
the pointer onto a stationary panel.

**Why it is not just a test artefact:** AppKit delivers `mouseEntered` reliably
when the pointer moves onto a stationary window, but not always when a window
slides under a stationary pointer. That happens in normal use — attaching a
display repositions the panel, and a live activity resizes it — so a real
crossing could be missed, leaving the notch unresponsive until the pointer moved
again.

**Fix:** both tracking views now observe `NSWindow.didMoveNotification` and
recheck containment against the pointer, reporting a transition if it changed.
Tracking areas remain the primary mechanism.

---

### 0a. Hover guards could pin the notch open indefinitely

**Found by:** tracing the guard lifecycle rather than by a failing test — the
guards were written to prevent interruption and were never checked for the
opposite failure.

Four defects, all in the global guard added in the previous pass:

1. **Settings pinned every notch on every display.** The guard suppressed
   closing whenever any non-panel window of ours held key focus. Settings stays
   key for as long as it is focused, so no notch could close while it was open.
2. **Guards were app-wide, not per-notch.** Typing in the built-in display's
   notch suppressed closing on the external one.
3. **`draggingExited` did nothing.** A drag that entered the catcher and left
   without dropping opened the notch and left nothing to close it.
4. **Any mouse button held anywhere pinned everything** — including a button held
   while scrolling in another app.

**Fix:** interaction is now an explicit, owned, per-notch claim
(`NotchInteraction`). A claim is taken by a named owner against one notch for a
stated reason, released explicitly, and revalidated against its own condition so
a missed release cannot leave anything stuck. Nothing expires on a clock; claims
end when their premise does. Closing a notch releases every claim it holds.

Application-modal sheets remain the one genuinely app-wide hold-off, and they are
inherently transient.

**Verification:** eleven assertions in "Interaction ownership", including that a
claim on one display does not pin another and that a Settings-like key window
pins nothing.

---

### 0b. Internal transitions were logged as `programmatic`

**Found by:** an intermittent provenance assertion — roughly 1 run in 4 attributed
a scripted open to `programmatic`.

Fullscreen suppression, lock/unlock, wake, outside-clicks and the collapse button
all called `open`/`close`/`toggle` without naming a cause, so the transition log
attributed them to the default. That undermines the whole point of provenance:
a log that cannot tell a system event from a user action proves nothing.

**Fix:** every internal transition now names its cause. The relevant assertions
also search for the most recent open (or close) rather than the very last entry,
since a system event can legitimately interleave.

---

### 0c. `ingest` conflated "how many rows appeared" with "was this understood"

Re-dropping a file already on the tray added nothing and reported nothing
handled, so AppKit played the rejection animation for a perfectly good drop.
`IngestOutcome` now separates `added` from `duplicates`; the drop handlers report
`recognised > 0`, and the Tray says "Already in the Tray" rather than appearing
to do nothing.

---

### 0d. A missing file could still be dragged out of the Tray

`NSItemProvider(contentsOf:)` returns nil for a file that has been moved or
deleted, and the row handed back an empty provider — the drag would start and
deliver nothing, which reads as the receiving app misbehaving. Rows whose file
is gone are no longer draggable.

---

### 0. `ingest` reported items it had not added

**Observed:** the "Tray (real files)" fixture test caught a duplicate drop
reporting `added 2` while the tray count was unchanged.

**Why it mattered:** the return value decides whether a drop is reported as
handled. A duplicate drop claimed success while nothing changed, so the UI would
show a successful drop for a tray that had not moved.

**Fix:** `add(_:)` returns whether the tray actually changed and
`add(contentsOf:)` counts real additions, so `ingest` reports what happened
rather than what was attempted.

---

### 1. Notch could stay open after the pointer had left

**Observed:** 1 failure in 5 consecutive runs of `--self-test` at `46d69bf`:

```
run 1: 164 passed, 1 failed
      ✗ moving the pointer off it collapses again  — still open
run 2..5: 165 passed, 0 failed
```

**Why it matters:** the test slides the panel out from under a stationary
cursor and expects `mouseExited`. If AppKit does not always deliver that exit
when a *window moves* rather than the pointer, the same gap exists in the real
app: the notch could stay open after the pointer has left. The notch has no
periodic "is the pointer still inside?" re-check to fall back on.

**Cause:** confirmed real, not a test artefact. Hover is driven by tracking
areas — the right mechanism, and the only one that works without Accessibility —
but `mouseExited` is not guaranteed when a *window* moves out from under a
stationary pointer. A display change, a live activity resizing the panel, or the
notch collapsing can all move it, and a missed exit left the notch open with the
pointer nowhere near it.

**Fix:** a fallback that closes a notch the pointer has demonstrably left. It
ticks once a second, only while something is open, and uses a 24pt margin so it
can never fight legitimate hover. Tracking areas remain the mechanism; this only
catches the dropped event.

**Verification:** 20 consecutive runs of a **frozen** binary at 216 assertions,
0 failures (previously 1 failure in 5 runs). Frozen deliberately: an earlier
16-run attempt straddled rebuilds — assertion counts climbed from 188 to 207
across it — and was therefore worthless as single-build evidence.

**Follow-up found while auditing it:** the recovery check was starting at launch
rather than on first open, because the state observer fires on subscribe. An
idle Mac was being polled once a second for nothing. It now starts only when
something is open and is cancelled the moment the last notch closes.

---

### 2. Hover was never actually confirmed by a watcher

A previous session armed a window-geometry watcher and reported it had recorded
nothing, so hover on the installed app was described as unverified.

**Now confirmed.** Re-reading the complete log showed seven open→close pairs
between 09:57:33 and 10:00:22 on the built-in display, all *before* the first
scripted open of that session at 10:01, against the live app instance. Self-test
panels carry different window ids and cannot account for them, and the ~2s
open-then-close cadence is hover rather than a scripted command.

Hover on the **external** display is still unobserved.

**Provenance now recorded.** Window geometry alone cannot distinguish a physical
hover from a scripted command or from the recovery fallback.
`NotchTransitionLog` records the cause of every transition (`trackingArea`,
`explicitCommand`, `pointerFallback`, `escape`, `outsideClick`, `drag`,
`systemState`, `programmatic`) with the display and window it belongs to, and
nothing else — no titles, paths or user content. `--transitions` prints it.
