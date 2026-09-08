# LocalNook — hands-on acceptance

Everything below needs a real pointer, a real keyboard, or a real Finder drag.
None of it can be inferred from a command-driven open or a pasteboard test, so
none of it is marked passed until you say what happened.

Record each line as **pass**, **fail** (say what you saw), or **skip**.

---

## Before you start

**Where the app is.** The working copy is `/Applications/LocalNook.app`. That is
the one Spotlight, Launchpad and Finder open — LaunchServices resolves
`com.localnook.app` to it, confirmed after clearing 37 dead registrations left
behind by earlier builds.

`dist/LocalNook.app` inside the repo is the same build, kept as the release
artifact. Don't launch that one; it is not the installation.

**Fixtures.** `~/Desktop/LocalNook-acceptance/`

| | |
|---|---|
| `drag-into-tray/` | six files to drag in — a PNG, a TXT, a CSV, an MD, a folder, and one with a deliberately long name |
| `drag-out-target/` | empty; drag things back out into this |
| `baseline-checksums.txt` | what the originals hashed to before you started |

Delete the whole folder when you're done. Nothing outside it is touched.

**The tray starts empty** so that step 5 is unambiguous — anything in it got
there from your drag.

**Displays: 2 connected** (built-in + G274QPF E2). The app is showing 4 windows,
one panel and one catcher per display.

**A note on step 5.** The tray-label fix ships in this build. If you see
`imag…e.png` rather than `image-fixture.png`, you are running an older copy —
check with:

```bash
shasum -a 256 /Applications/LocalNook.app/Contents/MacOS/LocalNook
```

---

## The checklist

### 1. Hover — open, enter, leave, reopen

1. Move the pointer onto the notch at the top-centre of the **built-in** display.
2. It should expand after ~0.1s.
3. Move the pointer down *into* the expanded panel. It should **stay open**.
4. Move the pointer away entirely. It should collapse.
5. Hover again. It should reopen.

**Expected:** opens on hover; stays open while the pointer is inside it; closes
on leaving; reopens cleanly. No flicker at the boundary between the small
catcher and the expanded panel.

**Watch for:** opening and then immediately snapping shut as you move down into
it — that boundary is the one place the hand-over between the two windows could
go wrong.

### 2. Notes — type, Escape, Escape

1. Open the notch, go to **Tools**, open **Notes**.
2. Click into a note and type a few words. Look away from the notch while typing
   — the pointer will not be over it.
3. Press **Escape** once.
4. Press **Escape** again.

**Expected:** it stays open the whole time you're typing, even with the pointer
elsewhere. First Escape leaves the text field but leaves the notch open. Second
Escape closes the notch.

**Watch for:** the notch closing under you mid-sentence, or the first Escape
closing the whole thing.

### 3. Settings — must not pin the nook

1. Open the notch, click the **gear**.
2. Settings opens as its own window and takes focus.
3. Move the pointer away from the notch.

**Expected:** the notch closes normally. Settings staying open is *not* a reason
for the notch to stay open.

4. Close Settings. The notch should still behave normally on hover.

### 4. Overflow — open, use, resize, dismiss

The dashboard is currently configured with **6 widgets** so the overflow control
is present (I changed this for the test — restore command at the bottom).

1. Open the notch on **Dashboard**. Bottom-right of the row you should see a
   timer glyph with a **blue "3"** badge and the label **More**.
2. Click it.
3. It should take you to **Tools** with the hidden widgets reachable.
4. Use one of them — start a timer, say.
5. Come back to Dashboard.

**Expected:** nothing enabled is unreachable. The badge count matches the number
of widgets that didn't fit.

### 5. Tray — drag in from Finder

1. Open `~/Desktop/LocalNook-acceptance/drag-into-tray` in Finder.
2. Open the notch on the **Tray** page.
3. Drag `notes-fixture.txt` from Finder onto the tray.
4. Drag the remaining five in, together as a multi-selection.

**Expected:** the drop zone highlights while a drag is over it; the item appears
with its real Finder icon; the count updates. Filenames should be **readable** —
`image-fixture.png`, not `imag…e.png`. Only the deliberately-long one truncates.

**Watch for:** the notch closing while you're mid-drag.

**Also worth a glance — not yet checked by me.** The tray label width changed
this pass (62pt → 90pt). I verified six items look right, but not twelve: the
row is a horizontal scroller, so more items should scroll rather than clip, and
I could not confirm that visually because `screencapture` is refused while the
screen is locked. If you drag in a dozen files, check the row scrolls and
nothing is cut off at the right edge.

### 6. Tray — drag back out

1. Drag `data-fixture.csv` from the tray into `drag-out-target/` in Finder.

**Expected:** a real copy lands in `drag-out-target/`. The tray entry stays.

### 7. Tray — remove, and check the original survives

1. Right-click `notes-fixture.txt` in the tray → **Remove**.

**Expected:** the entry disappears. The file is **still in
`drag-into-tray/`, unchanged**. Run this afterwards — it must print `OK`:

```bash
cd ~/Desktop/LocalNook-acceptance && shasum -a 256 -c baseline-checksums.txt
```

### 8. Mirror — explicit start, and it must stop

1. Dashboard → **Mirror**. It should show a camera glyph and **not** be running.
   The camera indicator light must be **off**.
2. Click it to start. Grant camera access if macOS asks.
3. The light comes on, you see yourself.
4. Move the pointer away so the notch closes.

**Expected:** the camera indicator light goes **off** within a second or two of
the notch closing. This is the one to be fussy about.

---

## With the second display connected

### 9. Hover on the external display

Same as step 1, but on the **G274QPF E2**.

**Expected:** identical behaviour. This is the check that has never been
performed — see BUGS.md § "Hover: what is actually still open". If it opens on
the built-in display but not the external one, that is a real defect and worth
stopping for.

### 10. Independent ownership across displays

1. Open the notch on the **built-in** display and start typing in Notes.
2. While that is still open, hover the notch on the **external** display.

**Expected:** both can be open at once. Typing on one must not pin the other.
Moving the pointer off the external one closes *it* while the built-in one stays
open because you're still typing in it.

### 11. Drag between displays

Drag a file from Finder on one display into the tray on the **other** display.

**Expected:** it lands in that display's tray, and the notch you're dragging
over doesn't close mid-drag.

### 12. Disconnect and reconnect

1. Unplug the external display while its notch is **open**.
2. Plug it back in.

**Expected:** no leftover windows, no black bar on the remaining display, and
the notch works on both after reconnecting.

Run this at each step. It reports only the *installed* app's windows and says
whether the count matches the display count, so it stays meaningful even if
something else called LocalNook is running:

```bash
~/Desktop/LocalNook-acceptance/window-count
```

It should say `OK — one panel and one catcher per display` throughout: 4 windows
with both displays attached, 2 while the external one is unplugged. Anything
else — especially a leftover catcher — is a defect worth stopping for, because
an invisible catcher sitting on the menu bar still eats clicks.

---

## 13. One test for me — takes ten seconds

Do this at any point **while you are actively using the mouse**, not after
walking away:

```bash
/Applications/LocalNook.app/Contents/MacOS/LocalNook --self-test --integration
```

**Expected:** `integration: 10 passed, 0 failed`, and each `probe:` line reads
`enters=1 … handled=1` with a **low** `idle=` figure.

**Why it matters.** The long-standing "roughly 1 hover crossing in 12 goes
missing" was never intermittent. It was the **screen being locked** —
`loginwindow` sits above everything and a background app receives no
tracking-area crossings underneath it.

I got this wrong once before concluding it: idle time correlated beautifully
across twenty-odd runs and was not the cause. Waking the display with
`caffeinate -u` reset the idle counter to single digits and the crossings still
did not arrive; enumerating the windows under the pointer found `loginwindow`
covering the screen.

The suite now detects this itself and says so rather than guessing:

```
? [integration] hovering the notch opens it — UNVERIFIED: the screen is locked;
  loginwindow is above every window, so no crossing can reach the panel
```

So this step is the one measurement nobody has: an integration run on an
**unlocked** screen. Clean is the expected answer. `enters=0` on an unlocked
screen would be a genuine finding and worth stopping for. Please paste whatever
it prints.

---

## When you're done

Restore the dashboard to its normal three widgets:

```bash
python3 -c "import json,subprocess;subprocess.run(['defaults','write','com.localnook.app','widgets.dashboard','-data',json.dumps(['media','mirror','calendar']).encode().hex()])" && pkill -f "/Applications/LocalNook.app/Contents/MacOS/LocalNook"; open -a /Applications/LocalNook.app
```

And remove the fixtures:

```bash
rm -rf ~/Desktop/LocalNook-acceptance
```
