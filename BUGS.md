# LocalNook — known bugs

Recorded during development. Each entry says how it was observed, so it can be
reproduced rather than taken on trust.

---

## OPEN

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

### 0-. `stop()` left the recovery check running

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

### 0. A window moving under a stationary pointer could miss the crossing

**Observed:** 1 failure in 2 runs of the frozen build-21 binary —
`hovering the notch opens it — tracking area did not deliver mouseEntered`.

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
