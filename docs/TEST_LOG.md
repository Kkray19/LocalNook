# LocalNook — test log

Two layers of verification, because XCTest is unavailable under Command Line
Tools (it ships with full Xcode only).

## 1. Automated: `LocalNook --self-test`

Runs in-process against the real singletons and the real view hierarchy. It is
wired into `scripts/build-release.sh` and **blocks packaging on failure**.

```
$ dist/LocalNook.app/Contents/MacOS/LocalNook --self-test
64 passed, 0 failed
```

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

## Known gaps in coverage

- **Live on-screen hover on the physical notch** has not been observed directly:
  synthesising pointer movement requires Accessibility, which is not granted.
  It is covered by the end-to-end test, which drives the real panel and view.
  A five-second manual check (hover the notch) would confirm it in situ.
- **External display** behaviour is untested — only one display is attached to
  this machine.
- **Sleep/wake** handling is implemented and wired to `NSWorkspace.didWake`, but
  has not been exercised through a real sleep cycle.
- **Permission-denied paths** are asserted structurally rather than by actually
  revoking each permission.
