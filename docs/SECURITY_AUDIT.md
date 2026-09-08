# LocalNook — security & privacy audit

Audit performed against the release build. Re-run any of these commands yourself;
they are all reproducible.

---

## 1. Network activity — none

**Source scan**

```
grep -rn "URLSession\|NSURLConnection\|NWConnection\|socket(\|http://\|https://" Sources/ --include="*.swift"
```
Result: **no matches** other than licence URLs inside comments.

**Binary scan** — more authoritative than grep, because it covers anything the
compiler actually linked:

```
nm -u dist/LocalNook.app/Contents/MacOS/LocalNook | grep -icE "URLSession|CFSocket|NWConnection|getaddrinfo|CFHTTP"
```
Result: **0**.

`otool -L` shows no `CFNetwork` and no `Network.framework`. LocalNook cannot
make a network request; the code to do so is not linked in.

**Runtime check** — app launched, left idle, then:

```
lsof -p <pid> -i -a
```
Result: **no open sockets of any kind**.

### Deliberate design consequences

Two features were built the harder way to keep this true:

- **Album artwork** is not fetched from Spotify's artwork URL. A deterministic
  gradient is generated from a hash of the track instead.
- **No update checker.** Upstream boring.notch bundles Sparkle; it was dropped
  rather than ported.

## 2. Credentials and secrets — none

```
grep -rniE "api[_-]?key|secret|passwd|bearer token" Sources/ --include="*.swift"
```
Result: **no matches**. LocalNook has no account, no licence check and no
server to authenticate against, so it has nothing to store.

## 3. Telemetry and analytics — none

```
grep -rniE "analytics|telemetry|mixpanel|sentry|firebase|amplitude|crashlytics" Sources/ --include="*.swift"
```
Result: one match — the sentence in the About pane stating that there is none.

## 4. Subprocess execution — one call site, injection-safe

The only `Process()` in the codebase is `ProcessRunner.run` in
`Features/Shortcuts/ShortcutsManager.swift`.

- The executable is the hardcoded literal `/usr/bin/shortcuts`.
- Arguments are passed via `Process.arguments`, i.e. as separate `argv` entries.
- **No shell is involved anywhere.** There is no `/bin/sh -c`, no string
  interpolation into a command line, and no `system()`/`popen()`.
- `standardInput` is `FileHandle.nullDevice`, so a subprocess can never block
  waiting on a prompt.

A shortcut named `; rm -rf ~` is therefore just a name. Shell injection is not
mitigated here — it is structurally impossible.

## 5. Private API use — one file, opt-in, off by default

`Sources/LocalNook/Vendor/ElevatedWindowSpace.swift` is the only file touching
undocumented API (the CoreGraphics Spaces calls, used to float above full-screen
apps).

- Gated behind **Settings ▸ Notch ▸ Advanced**, which is **off by default**.
- With it off, none of the symbols are ever resolved or called.
- Symbols are resolved with `dlsym` rather than `@_silgen_name`, so if a future
  macOS removes them the initialiser returns `nil` and LocalNook silently falls
  back to a standard window level. It cannot fail to launch because of this.

## 6. Entitlements — none requested

```
codesign -d --entitlements - dist/LocalNook.app/Contents/MacOS/LocalNook
```
Result: **empty**. LocalNook requests no entitlements at all. It is ad-hoc
signed (`Signature=adhoc`, `TeamIdentifier=not set`), which is sufficient to run
and to hold TCC permissions on the machine that built it.

## 7. Permissions — all lazy, all degrading

No permission is requested at launch. Each is asked for the first time the
feature that needs it is used, and refusing one disables only that feature.

| Permission | Requested when | If refused |
|---|---|---|
| Calendar | Calendar widget first shown | Widget explains and links to Settings |
| Camera | Mirror widget first shown | Widget explains and links to Settings |
| Notifications | A timer first completes | Falls back to an audible beep |
| Automation | First media poll | Media widget explains and links to Settings |
| Accessibility | **Never requested** | — |

LocalNook never asks for Accessibility. The HUD feature reads volume through
public CoreAudio APIs instead, which is why it cannot suppress the system HUD.

## 8. File handling

- **The shelf references files in place.** Dropping a file records its path; it
  does not copy the file. Removing a shelf item deletes the underlying file
  **only** when LocalNook created it (`isOwned`), which happens solely for
  dragged text with no file of its own.
- Own data is written to `~/Library/Application Support/LocalNook/`, created
  with default permissions, using atomic writes.
- No temporary files are created in world-writable locations such as `/tmp`.

## 9. Agent session monitoring — metadata only

The Sessions widget watches `~/.claude/projects` and `~/.codex/sessions`. This
is the most privacy-sensitive feature in the app, so to be explicit:

- It reads **`URLResourceValues` only** — path, modification date, file size.
- It **never opens a transcript file** and never reads a line of any conversation.
  There is no `Data(contentsOf:)`, `String(contentsOf:)` or `FileHandle` read
  anywhere in `SessionMonitor.swift`.
- Project names are derived from **directory names**, not file contents.
- Nothing leaves the machine — see §1.
- The whole feature can be switched off in Settings ▸ Widgets.

## 10. Measured resource use

Release build, launched and left idle:

| Metric | Value |
|---|---|
| CPU (26s idle) | **0.0 %** |
| Resident memory | **~46 MB** |
| Threads | 3 |
| Open sockets | 0 |

This is a consequence of the polling discipline: media polling stops entirely
when no media app is running, battery and audio changes arrive as system
callbacks, session monitoring uses `DispatchSource` kernel events, and the timer
tick only exists while a timer is running.

---

## Findings

**No issues found.** The two items worth a reader's attention are documented
rather than hidden:

1. The opt-in private-API file (§5) — off by default, fails soft.
2. The single subprocess call site (§4) — injection-safe by construction.
