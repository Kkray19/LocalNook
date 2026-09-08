# LocalNook — known bugs

Recorded during development. Each entry says how it was observed, so it can be
reproduced rather than taken on trust.

---

## OPEN

### 1. `testHoverPath` intermittently fails to collapse

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

**Status:** under investigation. Not yet reproduced against the installed app,
only the harness.

---

## RESOLVED

### Hover was never actually confirmed by a watcher

A previous session armed a window-geometry watcher and asked for a manual hover.
The log recorded only its own arming lines — no transitions — so **hover on the
installed app was never demonstrated**. Earlier phrasing that implied otherwise
was wrong; the only real evidence is `testCatcherHover`, which drives the
shipped catcher in-process.
