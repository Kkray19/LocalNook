# LocalNook — checks that need a human

Everything else is covered by `--self-test` or by driving the installed app.
These need physical pointer input, which cannot be synthesised without granting
Accessibility — a permission LocalNook deliberately does not require, and which
should not be granted merely to let a test pass.

Each item says what to do and what should happen. Five minutes total.

---

## 1. Finder drag-and-drop  *(the main gap)*

1. Open a Finder window with a few files.
2. Drag one onto the notch. → The notch opens on the **Tray** page and the drop
   area turns **blue with a dashed border**.
3. Release. → The file appears with its real Finder icon and name.
4. Drag two more in at once. → Both appear; the count updates.
5. Drag the same file in again. → Nothing is added; the count does not change.
6. Drag an item from the Tray back out to a Finder window. → Finder copies it.
7. Delete one of the originals in Finder, reopen the Tray. → That item is marked
   as missing (amber outline) rather than silently doing nothing when clicked.
8. Remove an item from the Tray with the − button. → **The original file is
   still in Finder.** This is the one that matters most.

## 2. Drag across displays

Drag a file onto the notch on the **G274QPF E2**, not the built-in.
→ That display's notch opens; the built-in one stays collapsed.

## 3. Hover on the external display

Move the pointer onto the external display's virtual notch and rest it there.
→ It expands. Move away. → It collapses.

Hover on the **built-in** display is already confirmed (see BUGS.md); the
external one has not been observed.

## 3b. Overflow

Make the panel narrow enough to overflow (Settings ▸ Notch ▸ Expanded size,
width ≈ 430), then open the nook.

1. → The right-hand column shows the **hidden section's own icon** with its name
   beneath — Calendar, not a bare "+1". With more than one hidden, it shows a
   count badge and "More".
2. Click it. → That section opens in Tools.
3. Press **Escape**. → It closes back to the Dashboard, not straight out of the
   nook, and nothing is left focused.
4. Widen the panel again while overflow is open. → The section returns to the
   Dashboard row and the overflow control disappears.

## 4. Typing in Notes

1. Tools ▸ Notes, type a sentence.
2. Move the pointer off the notch entirely and leave it there for five seconds.
   → **The notch must stay open while the text field has focus.** If it closes
   underneath you, the interaction claim has regressed.
3. Press **Escape** once. → The text field gives up focus; the nook stays open.
   Press Escape again. → The nook closes.
4. Click another app. → The nook closes on its own within about a second, because
   the panel resigned key and the text-editing claim ended.
3. Quit LocalNook from the menu bar immediately after typing, relaunch, reopen
   Notes. → The sentence is still there.

## 4b. Settings must not pin anything

Open LocalNook Settings from the menu bar item, then hover the notch open and
move the pointer away.
→ **The nook still closes.** Previously any focused window of ours pinned every
nook on every display for as long as it stayed open.

## 5. Menus and popovers

Open the menu bar item's menu, or a context menu on a Tray item, and leave the
pointer away from the notch for several seconds.
→ The notch stays open until the menu is dismissed.

## 6. Camera

1. Dashboard ▸ Mirror. → The camera starts and the green light comes on.
2. Navigate to Tray. → **The light goes out.**
3. Hover the notch open and closed a few times without touching Mirror.
   → The light never comes on.

## 7. Sleep / wake and display changes

1. Sleep the Mac, wake it. → The notch is collapsed and correctly positioned on
   both displays.
2. Unplug the external display and plug it back in. → Exactly one notch per
   display, no leftovers. (`CGWindowListCopyWindowInfo` should show four
   LocalNook windows with both displays attached.)

---

## Failure-safe install

`scripts/install.sh` replaces the old `cp -R … /Applications`. Its failure paths
are covered by `scripts/test-install.py`, which runs entirely in temporary
directories it creates and deletes — it never targets, stops, or reads the real
installation.

What the script guarantees, in order:

1. **Validate before touching anything.** Bundle exists, `Info.plist` lints,
   signature verifies, the binary runs, and the deterministic suite passes.
   A candidate that fails any of these leaves the existing app untouched — the
   run changes nothing.
2. **Stop only the right process.** Matched on the target's executable *path*,
   not the process name, so a build-tree copy or a second checkout of the same
   app is left running. `TERM` first, `KILL` only if it will not exit, and a
   refusal to continue if it still will not.
3. **Stage beside the target.** Copied to a sibling of the target, hash-checked
   against the candidate and signature-verified there, so the target path is
   never a partial copy.
4. **Keep the previous copy.** The existing installation is *moved* aside, never
   deleted, and stays on disk until the replacement has been verified in place.
5. **Verify what landed.** Executable present, hash matches the candidate,
   signature verifies, binary runs.
6. **Restore on any failure.** The previous copy goes back and is relaunched if
   it had been running. If even that fails, the script prints the exact path the
   intact copy is sitting at rather than exiting quietly.
7. **Only then discard the backup.**

```bash
./scripts/install.sh                       # dist/LocalNook.app → /Applications
./scripts/install.sh --target /tmp/staging # somewhere disposable
./scripts/install.sh --no-launch
```

### What still needs a human

- Confirming the app relaunched into the menu bar and the notch is present after
  an install. The script reports the pid it launched and the path it launched
  from; that it is *visible* is not something it can check.
- Recovery from a target the user does not own or cannot write (a managed
  `/Applications`). The refusal path is covered; the remedy is not scripted.
