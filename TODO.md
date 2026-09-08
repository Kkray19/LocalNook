# LocalNook — known gaps and next steps

Honest list of what is not done, and why.

## Known limitations

- **Media sources are limited to Music and Spotify.** LocalNook reads playback
  over Apple Events, which only reaches apps with a scripting dictionary.
  Browser tabs and other Now Playing sources are invisible to it. The
  alternative — the private MediaRemote framework, or the prebuilt
  MediaRemoteAdapter binary upstream ships — was rejected: see
  ARCHITECTURE.md § Media. `MediaProvider` exists so another backend can be
  added without touching the UI.
- **Album artwork is generated, not fetched.** Spotify exposes artwork only as a
  remote URL, and LocalNook makes no network requests. Tracks get a stable
  gradient derived from a hash instead.
- **Bluetooth activities cover audio devices only.** `IOBluetooth` aborts the
  process in this environment and `CoreBluetooth` would need a permission prompt
  while only seeing peripherals we actively scan. A mouse or keyboard connecting
  raises no activity; AirPods and headphones do.
- **The HUD does not replace the system HUD.** It shows LocalNook's own
  indicator alongside the built-in one. Suppressing the macOS OSD needs a
  private entitlement or a media-key event tap, neither of which is worth the
  fragility for a cosmetic feature.
- **No unit test target.** `swift test` requires XCTest, which ships with full
  Xcode, not Command Line Tools. Verification is currently the
  `--render-preview` harness plus the manual matrix in docs/TEST_LOG.md.

## Not started

- Reordering widgets by drag in Settings (currently arrow buttons).
- Keyboard shortcut binding for open/close (upstream uses the KeyboardShortcuts
  package; would need a small local implementation).
- AirDrop initiation from the shelf.
- Per-display widget configuration (settings are currently global).

## Ideas

- A compact media scrubber directly in the collapsed notch.
- Session monitor: show token/turn counts if they can be derived from file size
  alone, without reading transcript contents.
