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

## Known gaps in coverage

- **Live on-screen hover on the physical notch** has not been observed directly;
  it is covered by the end-to-end test against the real panel and view. A
  five-second manual check (hover the notch) would confirm it in situ.
- **External display** behaviour is untested — only one display is attached to
  this machine.
- **Sleep/wake** handling is implemented and wired to `NSWorkspace.didWake`, but
  has not been exercised through a real sleep cycle.
- **Permission-denied paths** are asserted structurally rather than by actually
  revoking each permission.
