# LocalNook — start here

Updated: 2026-09-11. This file is the portable development context for the next
assistant. Read AGENTS.md and inspect current git status before changing anything.

## Branch in progress: `fix/idle-cpu-and-tray`

Two changes, committed separately, branched from `main` at `62370ff`:

1. **Idle CPU.** The collapsed notch burned a measured median 12.6% of a core
   (range 9.6–14.2%, 60s). Every sample was SwiftUI relayout driven by a
   `.repeatForever` animation that never lets the view graph go quiet; the busy
   spinner shows whenever any agent is working. Both indefinite indicators now
   animate as Core Animation layers, which the window server interpolates while
   the app sleeps. Full attribution, the bisect table and two measuring traps
   are in BUGS.md under "Idle CPU".
2. **Tray multi-item handoff.** macOS selection (plain / command / shift with a
   proper anchor) and an explicit "Drag all" / "Drag N" affordance that starts a
   real multi-file `beginDraggingSession`. Copy-only, missing files excluded and
   said so, duplicates handed over once, nothing copied to stage it. Row
   dragging is untouched: still one row, one file.

**Not yet done on this branch — it requires an unlocked screen and was left
undone rather than faked:**

- The post-fix CPU measurement of the same scenarios. `scripts/build-release.sh`
  refuses to produce a candidate while the screen is locked, because its
  self-test gate reports the session-label checks as UNVERIFIED — the reader
  declines to read transcripts while locked, which is a privacy property, not a
  fault. Nothing is installed from this branch yet; the running app is still
  `62370ff`.
- `verify-candidate.sh`, the installer/release/isolation checks, and installing.
- Every physical drag check in docs/MANUAL_CHECKS.md §1b.

**Measuring CPU here — read this before trusting a number.** `ps`'s `%CPU` is a
lifetime average and is useless for "what is it doing now"; difference the
cumulative CPU time instead. A locked screen or a slept display stops
compositing, so *every* variant reads ~0.4% and a broken build looks fixed —
always measure a second process as a canary in the same window. And `-key value`
launch arguments do **not** override preferences: `@Pref` reads
`object(forKey:) as? Bool` and the argument domain stores a string, so the cast
fails and the default is used silently.

## Current baseline

The user authorized moving the completed stabilization work onto `main` and
publishing `main` to the private `Kkray19/LocalNook` repository. This supersedes the
previous hold on merging main for this publication only. New development should
use a feature branch. `fix/stabilization` retains the previous development tip.

The application-source baseline is `2e3d8ca`. Publication preparation changes
only documentation. The last developer report identified installed binary SHA-256
`e7760293bf36e4d4f590205ab0f5002fb979287490d0c32b3ae02c14068cad29`,
and reported 10 clean deterministic and 12 clean integration runs on one display
(623 deterministic checks). These are prior reported results, not a fresh run
by the publication task. Verify the current installation before relying on them.

## Product and preferences

Native macOS notch utility with Dashboard, Tray, Tools and AI Sessions. Configurable
solid/Liquid Glass appearance, sizes and opacity. Pinned widgets that do not fit
have a More control. Camera/Mirror was removed by request.

The user's latest requested work was a fluid opening with a subtle settling bounce,
while leaving closing unchanged. Source now implements that motion. Subjective
acceptance of its final feel is not recorded here: ask for feedback before tuning.
Browser-media acceptance is paused behind the animation work.

AI labels and usage come from local agent files only when the applicable reading
choice permits them. Metadata-only must not read transcript bodies. Rich labels
are content: do not persist, log or include them in automated screenshots.
The usage ledger aggregates message usage incrementally; cache reads are separate
from fresh input/output. Rate-limit values are recorded snapshots, not live account
queries. Missing data must stay missing rather than be guessed.

## Key code

- `Sources/LocalNook/Notch/NotchWindowController.swift`: display ownership, drawing
  panels, input catchers, pre-open canvas preparation, delayed shrinking, teardown.
- `Sources/LocalNook/UI/NotchShape.swift`: `NotchMotion`, `OpeningMotion`, settling.
- `Sources/LocalNook/UI/NotchRootView.swift`: rendered shell/content and transitions.
- `Sources/LocalNook/UI/DashboardView.swift`: pinned layout and overflow.
- `Sources/LocalNook/Features/Media/`: provider capabilities, permission checks,
  browser tab candidates, browser-wide audio and optional page access.
- `Sources/LocalNook/Features/Sessions/`: monitor, bounded detail reads, token ledger,
  usage normalization and dashboard.
- `Sources/LocalNook/Core/Settings.swift`: settings and session-reading preference.
- `Sources/LocalNook/App/SelfTest.swift`: deterministic and live integration checks.

ARCHITECTURE.md explains the background. Older sections and TEST_LOG entries can
be stale; current source and dated evidence take precedence. In particular, the
panel is not permanently one fixed size: it prepares a wider canvas before opening
and holds it during closing, while SwiftUI animates within that canvas.

## Browser media limitations

Tier 1 knows candidate tabs and browser-wide audio, not the playing tab. Do not
infer paused from silence or label an arbitrary tab as playing. Per-tab controls
require optional page access and user-enabled browser scripting. Never enable it
silently. Installed-widget playback/control acceptance remains incomplete; staged
renders and parser checks do not prove it. Artwork remains deferred. Do not claim
all browsers or players have been verified.

## Build and test

Requires macOS, Apple Silicon, Swift 6.2+ compatible Command Line Tools/SDK.
Package.swift targets macOS 15; development used the macOS 27 SDK. No full Xcode
or external packages are required. The LNState shim addresses the CLT SDK macro.

From the repository root:

```sh
./scripts/build-release.sh
./scripts/verify-candidate.sh dist/LocalNook.app
./scripts/install.sh
```

The candidate verifier runs 10 deterministic and 12 integration iterations against
one frozen binary. Direct checks:

```sh
dist/LocalNook.app/Contents/MacOS/LocalNook --self-test --deterministic
dist/LocalNook.app/Contents/MacOS/LocalNook --self-test --integration
python3 scripts/test-install.py
python3 scripts/test-release.py
```

Read script arguments before use. The isolation test intentionally adds temporary
sentinels to the production domain/support directory and removes them; it is not
entirely confined to a disposable directory. Do not run it casually against user
activity. Core self-tests use disposable preferences/support state.

Exit 0 means clean, 1 means failure, 2 means unverified prerequisites. Locking the
screen, changing focus/pointer or disconnecting displays can affect live checks.
Never convert actual app defects to skips. Record conditions and all results.
Manual procedures live in docs/ACCEPTANCE.md and docs/MANUAL_CHECKS.md; read their
age/context and omit obsolete camera checks. Do not reinstall solely for docs.

## Next session

0. If `fix/idle-cpu-and-tray` is still unmerged: with the screen **unlocked**,
   run `./scripts/build-release.sh`, `./scripts/verify-candidate.sh
   dist/LocalNook.app`, then `./scripts/install.sh`; re-measure the collapsed,
   sessions-active, media-idle, expanded and two-display cases for 60s each and
   record medians and ranges; then walk docs/MANUAL_CHECKS.md §1b.
1. Read this file, AGENTS.md and git status/log.
2. Confirm the user's next objective; do not restart a broad stabilization audit.
3. If continuing animation, obtain feedback on the current landing before editing.
4. If resuming browser media, finish installed UI/permission and attribution checks.
5. Update this file with concrete changes, verification and remaining work.

## Reusable handoff prompt

> Continue LocalNook from the main branch of Kkray19/LocalNook. Read AGENTS.md and
> docs/HANDOFF.md, inspect the current code and git status, and summarize the next
> task before editing. Preserve the constraints and user data. My next request is:
> [describe the change]. Update the handoff when finished.

The repository is private. Each AI service needs authorized repository access;
sharing its URL does not make the code publicly readable. If a service cannot
connect, provide these two handoff files and the source relevant to the task.
