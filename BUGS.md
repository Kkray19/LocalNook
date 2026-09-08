# LocalNook bug register

Severity: P0 crash/data loss/security; P1 major feature; P2 usability; P3 polish.

## BUG-001

Status: Implemented; see verification limits below
Severity: P1
Component: Release

Steps to reproduce: Run a failing compilation or failing self-test with old dist outputs present.

Expected: No release artifacts on failure.

Actual: Old app/DMG remained visible; tests were skippable.

Root cause: Output removed too late; no freshness check; optional gate.

Fix: Stage privately, remove stale dist at entry, clean compile, require fresh executable, compare copied binary, mandatory tests, verify signature/DMG and add build identity.

Regression test: scripts/test-release.py exercises compiler, missing/stale binary and test failures.

Verification: Four failure scenarios pass; successful release gate exercised.

## BUG-002

Status: Implemented; see verification limits below
Severity: P0
Component: Persistence

Steps to reproduce: Load malformed notes.json or shelf.json, then edit/add an item.

Expected: Preserve unreadable original data.

Actual: Default empty state could overwrite the original.

Root cause: try? swallowed decoding/read failures.

Fix: Shared JSONFileStore blocks writes after read failure, retains bytes in place and exposes recovery error.

Regression test: Corrupt notes and shelf fixtures are compared byte-for-byte after mutation.

Verification: Pass; recovery is deliberately manual, with an explicit error in the widget.

## BUG-003

Status: Implemented; see verification limits below
Severity: P1
Component: Notes

Steps to reproduce: Edit, then quit within the 600ms autosave delay.

Expected: Last edit survives normal quit.

Actual: Pending edit was lost.

Root cause: Application termination did not flush NotesStore.

Fix: Synchronously flush on normal application termination; cancel pending debounce.

Regression test: Save immediately then reconstruct store with long Unicode notes and favorite/archived todos.

Verification: Flush/reload passes; force-kill before debounce remains a limitation.

## BUG-004

Status: Implemented; see verification limits below
Severity: P0
Component: Shelf

Steps to reproduce: Load an item with isOwned=true pointing outside ShelfItems, then remove it.

Expected: Never delete externally owned data.

Actual: Ownership flag authorized arbitrary file deletion.

Root cause: Persisted flag trusted without validating location.

Fix: Require canonical direct child of owned directory before deletion.

Regression test: Forged ownership fixture points to a disposable external file; verify it survives.

Verification: Pass; missing references also reload safely.

## BUG-005

Status: Implemented; see verification limits below
Severity: P0
Component: Self-tests

Steps to reproduce: Run --self-test with existing completed todos.

Expected: Tests cannot mutate user data.

Actual: Tests used real stores and archiveCompleted could archive user todos.

Root cause: Singletons bound to production directories/defaults.

Fix: Temporary support directory and dedicated defaults suite; remove tautologies and user transcript scans.

Regression test: All persistence regressions run in disposable fixtures; suite cleanup runs on exit.

Verification: Pass. Baseline ran the original suite once before isolation; it did not provide a way to reconstruct any prior todo archive state.

## BUG-006

Status: Implemented; see verification limits below
Severity: P2
Component: Hover

Steps to reproduce: Open, exit, and reenter before close delay expires.

Expected: Reentry cancels scheduled close.

Actual: Notch closed while pointer was inside.

Root cause: scheduleOpen returned for open state before canceling closeTask.

Fix: Cancel close first; reject open while suppressed.

Regression test: Timed reentry plus 100 interrupted transition cycles.

Verification: Pass with real AppKit event loop; hover window-under-pointer test passes without Accessibility.

## BUG-007

Status: Implemented; see verification limits below
Severity: P1
Component: Camera

Steps to reproduce: Open Mirror, immediately close while configuration is queued; let authorization/configuration finish.

Expected: No capture after close.

Actual: stop returned while isRunning was still false; late callback could restart/report running.

Root cause: Intent and asynchronous hardware state were conflated.

Fix: Capture demand generations, unconditional queued stop, stale callback rejection, main-actor selected-device identity.

Regression test: Fake capture driver drives actual manager through startup/stop/late callback and denied access.

Verification: Automated verification; physical green-indicator test pending camera consent.

## BUG-008

Status: Implemented; see verification limits below
Severity: P1
Component: Sessions

Steps to reproduce: Append to nested transcript, or let active session age without a root directory change.

Expected: Activity metadata updates and ages out.

Actual: Nested writes and active-to-quiet transition could remain stale.

Root cause: Directory vnode watch is not recursive; label timer did no rescan.

Fix: 20-second background metadata reconciliation, generation guards, settings refresh.

Regression test: Nested malformed bytes, stale metadata and missing-folder fixtures.

Verification: Pass. Timestamp status is now labeled as inferred activity, not proof an agent is working/waiting.

## BUG-009

Status: Implemented; see verification limits below
Severity: P1
Component: Shortcuts

Steps to reproduce: Run a process producing more than a pipe buffer on stderr, or one that never exits.

Expected: Output completes or a bounded timeout is reported.

Actual: Runner could deadlock forever; timeout argument was ignored.

Root cause: Sequential pipe drains and unbounded wait.

Fix: Separate temporary output files, bounded process wait/termination, bounded output reads and explicit argv.

Regression test: Actual hostile Unicode argv, >64KB stdout/stderr, sleep timeout, missing executable.

Verification: Pass. Timeout stops the direct process; independently spawned descendants remain a limitation.

## BUG-010

Status: Implemented; see verification limits below
Severity: P2
Component: Live activities

Steps to reproduce: Start/pause a timer or change media state; toggle activities off.

Expected: Banner reflects current state promptly.

Actual: Publishers emitted before their owner changed; reads could see previous state.

Root cause: Synchronous sink reread @Published owner during willSet.

Fix: Deliver recompute on run loop; honor settings changes; deduplicate identical transient activity.

Regression test: Real timer start/pause publisher integration.

Verification: Automated verification; hardware charging/audio event matrix pending.

## BUG-011

Status: Implemented; see verification limits below
Severity: P2
Component: Fullscreen

Steps to reproduce: Two equal-resolution displays; only one has a full-screen window.

Expected: Suppress only covered display.

Actual: Both could be marked covered.

Root cause: Compared dimensions without origin.

Fix: Compare full transformed screen rectangle including position.

Regression test: Synthetic equal-size displays with distinct origins.

Verification: Pass; physical multi-display matrix unavailable.

## BUG-012

Status: Implemented; see verification limits below
Severity: P2
Component: Panel geometry

Steps to reproduce: Inspect default window frame and drag near collapsed notch.

Expected: Bound overlay to needed content/shadow; no oversized drop area.

Actual: 944pt panel and enlarged invisible drop region.

Root cause: Added live-activity gutters to already-wide expanded geometry.

Fix: Window width is max of open/closed activity extents plus shadow; collapsed drop region matches visible body.

Regression test: Default panel extent plus live geometry/manual menu tests.

Verification: Default reduced to 732x214. Transparent menu pass-through requires composited UI verification, not just size assertion.

## BUG-013

Status: Implemented; see verification limits below
Severity: P2
Component: Hover diagnostics

Steps to reproduce: Repeatedly animate/rescale tracking view.

Expected: No unbounded diagnostic storage during normal use.

Actual: Array appended every tracking update and event.

Root cause: Comment claimed diagnostics were disabled; code always appended.

Fix: Record only under --self-test; bound to 200 entries.

Regression test: 300 diagnostic entries retain no more than 200.

Verification: Pass.

## BUG-014

Status: Implemented; see verification limits below
Severity: P1
Component: Media

Steps to reproduce: Launch with media app running; overlap refresh/poll; seek many distinct positions.

Expected: No launch consent prompt; coherent bounded snapshots.

Actual: Startup sent Apple Events; overlapping polls and unbounded compiled-script cache.

Root cause: Eager singleton polling and no poll guard/cache cap.

Fix: Enable polling on intentional Media widget use; serialize polling/discard canceled snapshots; cap script cache; clamp positions and preserve interpolated position on pause.

Regression test: Position bounds/NaN tests; source review for poll and cache guards.

Verification: Numeric tests pass. Real Music/Spotify transport/source takeover remains unverified; Spotify is absent.

## BUG-015

Status: Implemented; see verification limits below
Severity: P2
Component: Calendar

Steps to reproduce: Turn show-all off and deselect every calendar; revoke access.

Expected: Show no events; clear denied state.

Actual: Empty/stale selection fell back to all calendars.

Root cause: nil fallback means all calendars in EventKit.

Fix: Explicit empty selection; refresh authorization before queries; write-only treated as denied.

Regression test: Calendar selection policy tests.

Verification: Automated policy verified; no private calendar access granted during audit.

## BUG-016

Status: Implemented; see verification limits below
Severity: P2
Component: Window lifecycle

Steps to reproduce: Restart controller, rapidly change geometry, disable/re-enable fullscreen detection, lock then receive open command.

Expected: No duplicate observers/tasks or locked-screen reopens.

Actual: Observer tokens discarded; delayed tasks not coalesced; command ignored lock state.

Root cause: Closure observer lifetime and delayed task ownership absent.

Fix: Retain/remove tokens, guard lifecycle, cancel geometry tasks, cancel retired model tasks, honor lock state.

Regression test: Controller start/stop script tests plus transition stress.

Verification: Automated coverage; physical sleep/Spaces/lock matrix still pending.

## BUG-017

Status: Implemented; see verification limits below
Severity: P2
Component: License notices

Steps to reproduce: Inspect bundled notices against audited upstream reference.

Expected: Full retained MPL notice/copyright accompanies adapted source.

Actual: Only link/file header, no full MPL text or original copyright in bundle.

Root cause: Incomplete third-party notice packaging.

Fix: Include MPL-2.0.txt and upstream copyright; clarify verified GPL version evidence.

Regression test: Release verifies required notice copies exist.

Verification: GPL LICENSE matches reference checksum; local reference commit verified.

## BUG-018

Status: Implemented; see verification limits below
Severity: P2
Component: Settings

Steps to reproduce: Disable every widget, disable media artwork, inspect brightness HUD switches.

Expected: Disabled options affect behavior; unsupported features identified.

Actual: Media appeared with all widgets disabled; artwork ignored setting; unsupported HUD toggles implied functionality.

Root cause: Fallback widget and unused settings.

Fix: Explicit no-widgets state, honor artwork toggle, label brightness HUDs unimplemented.

Regression test: UI/source inspection; settings round-trip suite.

Verification: Needs full manual settings matrix; no redesign.

## BUG-019

Status: Implemented; see verification limits below
Severity: P2
Component: Live activity geometry

Steps to reproduce: Inspect collapsed activity around physical notch.

Expected: Empty camera strip stays centered.

Actual: Unequal shoulder widths and outside padding shifted strip.

Root cause: Leading/trailing widths and padding asymmetric.

Fix: Equal shoulder widths, internal padding.

Regression test: Equal shoulder invariant and real composited screenshot.

Verification: Layout fix awaiting final release screenshot.

## BUG-020

Status: Implemented; see verification limits below
Severity: P0
Component: Historical crash

Steps to reproduce: Run older bare executable which calls UNUserNotificationCenter without bundle.

Expected: No abort.

Actual: Two September 7 SIGABRT reports point to Permissions.refreshAll.

Root cause: Notification center requires bundle proxy.

Fix: Existing pre-stabilization guard retained.

Regression test: Bare executable --self-test notification guard.

Verification: Historical fix predates this pass; revalidation pending final bare-binary run.

## BUG-021

Status: Implemented; hardware transition verification pending
Severity: P2
Component: Volume HUD

Steps to reproduce: Enable volume HUD, change default audio output, then change volume.

Expected: Listener follows the new output and is removed from the old output.

Actual: Listener installation returns while an old listener exists; removal looks up the new default output.

Root cause: Registered device ID is not retained.

Fix: Retain registered output device; remove old listener and reattach on default-output change. Mute-listener coverage remains debt.

Regression test: Pending injectable CoreAudio driver.

Verification: Source-confirmed; hardware transition untested.

## BUG-022

Status: Implemented
Severity: P2
Component: Media parsing

Steps to reproduce: Play a track with a newline in title/artist/album, or localized numeric output.

Expected: All metadata and progress fields remain correctly separated.

Actual: Six-line parsing can shift fields; Double parsing assumes decimal point.

Root cause: Ad-hoc newline protocol between AppleScript and Swift.

Fix: Typed Apple-event list payload; native numeric descriptors avoid locale-dependent text conversion.

Regression test: Real NSAppleScript list with newline title, negative position and Spotify duration conversion.

Verification: Source-confirmed; real media library case not exercised.

## BUG-023

Status: Implemented; physical multi-display verification pending
Severity: P2
Component: Multi-display Mirror

Steps to reproduce: Show Mirror on two displays; close one preview.

Expected: Capture remains active for the other visible preview.

Actual: Shared manager receives stop from either view's onDisappear.

Root cause: Capture intent is global, without per-view usage tokens.

Fix: Per-view UUID preview leases; stop when the last visible preview releases its lease.

Regression test: Actual manager with two preview leases and fake capture driver.

Verification: Source-confirmed; only one display connected.
