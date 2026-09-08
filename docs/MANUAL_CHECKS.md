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

## 4. Typing in Notes

1. Tools ▸ Notes, type a sentence.
2. Move the pointer off the notch entirely and leave it there for five seconds.
   → **The notch must stay open while the text field has focus.** If it closes
   underneath you, the fallback's interaction guard has regressed.
3. Quit LocalNook from the menu bar immediately after typing, relaunch, reopen
   Notes. → The sentence is still there.

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
