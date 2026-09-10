# LocalNook contributor instructions

Read `docs/HANDOFF.md` first, then the relevant source. This is an existing native
macOS app, not a rebuild request. The user's current instruction takes precedence.

## Preserve

- Swift/SwiftUI/AppKit with Swift Package Manager; no external package dependencies.
- GPL-3.0-or-later and upstream attribution in THIRD_PARTY_LICENSES.md.
- Local-first behavior: no telemetry, backend, licence server, or added network service.
- Production preferences, notes, tray references and explicit session-reading choices.
- Camera/Mirror was deliberately removed. Do not reintroduce it without a request.
- Closing animation is intentionally preserved. Opening has a reversed approach
  followed by a small overshoot and settle. Do not retune either without feedback.
- Keep browser-media work paused unless the user resumes it. Never start audible
  playback, change system volume, or alter browser permissions for convenience.

## Work and verification

- Inspect git status before editing. Use a feature branch for new work; do not
  force-push, rewrite history, or publish tags without explicit authorization.
- Self-tests must use their disposable state, not restore snapshots over user data.
- Report passed, failed and unverified separately. Record lock state and display
  count for UI checks. Test counts can vary with environmental prerequisites.
- Synthetic tests are not evidence of actual Finder gestures or browser playback.
- Use scripts/build-release.sh and scripts/install.sh for releases. Do not remove
  the working installation before the replacement has been validated.
- Commit before building a release so its embedded revision identifies the source.
  Documentation-only commits do not require rebuilding an unchanged app.
- Track concrete bugs in BUGS.md with reproduction, cause, fix and verification.
- Read docs/HANDOFF.md's testing caveats before running checks.

## End each session

Update docs/HANDOFF.md with what changed, evidence, unresolved work, and the next
step. Avoid private transcripts, local usernames, credentials and personal usage
figures in new documentation or logs. Keep historical test reports as historical
rather than presenting them as current guarantees.
