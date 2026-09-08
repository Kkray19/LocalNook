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
