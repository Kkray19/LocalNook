# LocalNook — known bugs

Recorded during development. Each entry says how it was observed, so it can be
reproduced rather than taken on trust.

---

## OPEN

### Hover: what is actually still open

**Reclassified.** The single entry that used to sit here — "roughly 1 run in 12
misses a hover crossing" — turned out to be three different things wearing one
number. Separated, only one of them is still open, and it is not a product
defect.

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

#### 3. The platform gap — OPEN, and it is the harness's problem

**Reproducible symptom:** AppKit does not reliably deliver `mouseEntered` when a
*window* is moved out from under, or under, a stationary pointer. When it
happens the probe reads `enters=0`, and the check reports UNVERIFIED.

**Why it is not a product defect.** A user moves the pointer onto a stationary
panel. Moving the window instead is the only stimulus a test can produce without
Accessibility, and it is the one the window server treats differently. No run
has ever shown LocalNook receiving a crossing and dropping it (`eventDropped`)
or mishandling it (`wrongState`) — the two outcomes that *would* be defects, and
both of which fail the build.

**It is not intermittent. It is sticky, and it tracks machine idle time.**

This was mis-characterised for the whole of its life as "roughly 1 run in 12".
A batch of 12 integration runs against one frozen binary made the pattern
obvious:

| Runs | Result | Probe |
|---|---|---|
| 1–8 | clean | `enters=1 handled=1 opened-by: trackingArea` |
| 9–12 | UNVERIFIED | `enters=0 handled=0 opened-by: nothing` |

Three further runs immediately afterwards were also `enters=0`, and three more
after that: **seven consecutive**, not one in twelve. The variable that had
changed between run 8 and run 9 was not the binary, the displays, or the pointer
position — all constant. It was idle time. The machine had been untouched for
around half an hour, and after a long unattended stretch the window server stops
producing crossings for a window moved under a stationary pointer.

`HoverProbe` now prints `idle=NNNNs` in every provenance line, and the UNVERIFIED
message says so outright, so this cannot be re-filed against the app by the next
person to see it:

```
probe: enters=0 exits=0 handled=0 (of which containment=0) idle=2098s opened-by: nothing
? [integration] hovering the notch opens it — UNVERIFIED: … The machine had been
  idle 2098s; the window server stops delivering these crossings after a long
  unattended stretch. Re-run after using the mouse.
```

**Measurements, each against one frozen binary:**

| Binary | Displays | Runs | Result |
|---|---|---|---|
| `9df4dce2…` | 1 | 12 | 12 clean |
| `9df4dce2…` | 2 | 6 | 6 clean |
| `9c0ab374…` | 2 | 12 | 8 clean, then 4 `enters=0` at high idle |

**Why this still stays OPEN.** The idle correlation is strong but only tested in
one direction: it has been observed going from clean to `enters=0` as idle time
grew, never from `enters=0` back to clean, because returning to a low-idle state
requires real pointer input and this session cannot produce it. Until that
second direction is observed, "idle causes it" is a well-supported explanation
rather than a demonstrated one.

**What would establish resolution — a falsifiable prediction.** Use the mouse
for a moment, then immediately run:

```bash
/Applications/LocalNook.app/Contents/MacOS/LocalNook --self-test --integration
```

If the idle explanation is right, this comes back clean with `enters=1
handled=1` and a low `idle=` figure. If it comes back `enters=0` with a low
`idle=` figure, the explanation is wrong and the whole entry needs reopening on
different terms. Step 13 of docs/ACCEPTANCE.md asks for exactly this.

Separately, hands-on confirmation that hover works with a real pointer on both
displays (steps 1 and 9) is what actually matters, because it tests the gesture
users make rather than the substitute the harness is forced to use.

**Not in scope for a code change.** No speculative fix should be attempted
against item 3: an earlier attempt to re-check containment on window moves made
real hover measurably worse (1 clean run in 10, against ~14 in 15) and was
reverted. See the reverted-fix note under RESOLVED.

### 0-2disp. Two checks took an arbitrary notch and failed once a second display appeared

**Found by:** reconnecting the external display. Two deterministic checks that
had been clean for hundreds of runs started failing intermittently — the
fallback hold-off about 2 runs in 3, the claim-release check about 1 in 3.

**Cause:** the same defect in both, and it was in the tests. They used
`controller.allModels.first` — an arbitrary dictionary entry — while
`controller.perform(.open)` routes to whichever display the pointer is on. With
one display those were always the same model. With two they often were not, so
the hold-off check parked the injected pointer on one screen's notch while a
different screen's notch was the open one, and then read the entirely correct
per-display close as a failure to hold off. The claim-release check simply
never opened the notch it was asserting about.

**Worth stating plainly:** this looked exactly like a product defect —
"the fallback closed a notch the pointer was resting on" is a serious-sounding
failure — and it was not one. Nothing in the app changed. Both checks now act
on a model they have identified rather than one they hope is the right one.

**Lesson recorded in docs/TEST_LOG.md:** the number of attached displays is a
test input, not background. Changing it means re-running the deterministic
suite.

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

**What is not:** the drag *gesture* from Finder into the panel, and dragging an
item back out. Both need synthesised pointer input, which requires Accessibility.
The handling code is covered; the interaction is not.

**Manual check:** see docs/MANUAL_CHECKS.md.

---

## RESOLVED

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
