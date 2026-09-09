//
//  BrowserMedia.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Reading what a browser is playing, without a browser extension.
//
//  ── What is possible here, established by measurement ─────────────────────
//
//  MediaRemote — the private framework that used to expose a system-wide
//  now-playing feed — was probed directly from this app on this Mac (macOS
//  27.0): the framework loads, the symbol resolves, the callback fires, and the
//  payload is nil while QuickTime is confirmed playing. That result is scoped
//  to what it is: one unsigned-for-that-entitlement app, one machine, one OS
//  version. It is consistent with the entitlement gating Apple introduced in
//  macOS 15.4, but a single nil is not proof that no configuration anywhere
//  gets an answer. It is enough to establish that LocalNook cannot rely on it,
//  which is the only claim being made. No MediaRemote code ships here.
//
//  What remains is two public mechanisms, with genuinely different capability:
//
//    Tier 1 — tab title + browser audio.  The scripting dictionary gives the
//    title and URL of every tab, with no JavaScript involved. Public CoreAudio
//    says whether the *browser* is emitting audio. Together: what is open, and
//    that the browser is making a noise. NOT which tab is making it. See below.
//
//    Tier 2 — page access.  With "Allow JavaScript from Apple Events" switched
//    on by the user, `execute javascript` reaches each page's own media
//    element: exact paused/ended/muted state, position, duration, and working
//    transport controls. This is the only tier that can name the playing tab.
//
//  Tier 2 cannot be enabled programmatically, and should not be: it lets any
//  scripting client run arbitrary JavaScript in every tab. It is offered as an
//  explicit choice with the cost stated, and Tier 1 works without it.
//
//  ── Why Tier 1 cannot name the tab, structurally ───────────────────────────
//
//  Two independent facts, both checked rather than assumed:
//
//    * Neither browser publishes per-tab audio. Chrome's `tab` class is `id`,
//      `title`, `URL`, `loading`. Safari's is `source`, `URL`, `index`, `text`,
//      `visible`, `name`. Read straight out of their .sdef files. There is no
//      "audible" or "playing" property to ask for.
//
//    * CoreAudio attributes output to a process, and Chrome mixes every tab's
//      audio in one shared process. Measured on this machine: of Chrome's 20
//      running processes there is exactly one utility with
//      `--utility-sub-type=audio.mojom.AudioService`. Per-tab attribution is
//      not merely unimplemented, it is not expressible.
//
//  So under Tier 1 the honest report is "the browser is emitting audio", with
//  the tab's own playback state marked unknown. When one media tab is open that
//  is still worth naming; when several are, naming one would be a coin toss,
//  and the browser is named instead.
//
//  ── Permissions ────────────────────────────────────────────────────────────
//
//  Reading tabs at all requires Automation consent for that browser. Consent is
//  read with AEDeterminePermissionToAutomateTarget before any event is sent, so
//  opening the dashboard or polling in the background can never raise a prompt;
//  asking for it is a separate, explicit user action.
//

import AppKit
import Foundation

/// A browser LocalNook can read playback from.
nonisolated enum MediaBrowser: String, CaseIterable, Identifiable, Sendable {
    case chrome
    case safari

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chrome: "Google Chrome"
        case .safari: "Safari"
        }
    }

    var bundleID: String {
        switch self {
        case .chrome: "com.google.Chrome"
        case .safari: "com.apple.Safari"
        }
    }

    /// Where the user turns on page access, quoted exactly as the menus read.
    var javaScriptToggleHint: String {
        switch self {
        case .chrome: "View ▸ Developer ▸ Allow JavaScript from Apple Events"
        case .safari: "Develop ▸ Allow JavaScript from Apple Events"
        }
    }
}

/// What a page said about its own media element.
///
/// Only ever produced by Tier 2. Every field here is the page's own answer, so
/// this is the one source in the browser path that can be called authoritative.
nonisolated struct PageMedia: Equatable, Sendable {
    var isPaused: Bool
    var isEnded: Bool
    var isMuted: Bool
    var position: Double
    /// nil when the duration is not a finite positive number: a livestream, or
    /// metadata that has not arrived yet. Not zero — zero is a length.
    var duration: Double?

    /// Muted counts as playing. The page knows it is running; CoreAudio can
    /// only hear silence, so the page wins.
    var isPlaying: Bool { !isPaused && !isEnded }
    /// Stopped part-way through, rather than never started.
    var isPausedMidway: Bool { isPaused && !isEnded && position > 0 }
}

/// One media tab found in a browser.
nonisolated struct BrowserMediaTab: Equatable, Sendable {
    /// Stable identity for stickiness across polls: Chrome's own tab id, or
    /// the URL in Safari, which has no tab id to give.
    var key: String
    var title: String
    var url: String
    var site: String
    /// Present only when page access is on *and* the page had a media element
    /// this code could reach. Absent means "not known", never "not playing".
    var page: PageMedia?
}

/// Title and URL handling, kept free of AppleScript and CoreAudio so it can be
/// tested against fixtures rather than against a running browser.
nonisolated enum BrowserMediaParser {
    /// Sites whose tabs are worth treating as media.
    ///
    /// A deliberate allow-list rather than "any tab with audio": the title of an
    /// arbitrary page is not something to put on the menu bar, and a person's
    /// open tabs are their business. Matching is on host and path so that
    /// `youtube.com/watch` counts and `youtube.com` alone does not.
    static let knownSites: [(host: String, path: String?, name: String)] = [
        ("music.youtube.com", nil, "YouTube Music"),
        ("youtube.com", "/watch", "YouTube"),
        ("youtube.com", "/live", "YouTube"),
        ("open.spotify.com", nil, "Spotify Web"),
        ("soundcloud.com", nil, "SoundCloud"),
        ("music.apple.com", nil, "Apple Music"),
        ("twitch.tv", nil, "Twitch"),
        ("vimeo.com", nil, "Vimeo"),
        ("bandcamp.com", nil, "Bandcamp"),
    ]

    /// The site a URL belongs to, or nil when it is not a recognised player.
    static func site(forURL raw: String) -> String? {
        guard let url = URL(string: raw), let host = url.host?.lowercased() else { return nil }
        let path = url.path
        for entry in knownSites {
            let matchesHost = host == entry.host || host.hasSuffix("." + entry.host)
            guard matchesHost else { continue }
            if let required = entry.path {
                guard path.hasPrefix(required) else { continue }
            }
            return entry.name
        }
        return nil
    }

    /// A tab title cleaned into something worth reading.
    ///
    /// Browsers decorate titles: YouTube prefixes an unread count as "(72) ",
    /// and every site suffixes its own name. Both were present in the very
    /// first real capture taken while building this, so both are handled.
    static func cleanTitle(_ raw: String, site: String?) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Leading notification count, e.g. "(72) Some Video".
        if text.hasPrefix("("), let close = text.firstIndex(of: ")") {
            let inside = text[text.index(after: text.startIndex)..<close]
            if !inside.isEmpty, inside.allSatisfy({ $0.isNumber || $0 == "+" || $0 == "k" }) {
                text = String(text[text.index(after: close)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        // Trailing site name, e.g. "… - YouTube".
        for suffix in [" - YouTube", " — YouTube", " | Spotify", " - SoundCloud",
                       " on Vimeo", " - Twitch", " | Apple Music"] {
            if text.hasSuffix(suffix) { text.removeLast(suffix.count); break }
        }

        // Stripping the suffix from " - YouTube" leaves a bare separator, which
        // is not empty and would otherwise be shown as the track title.
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " -—–|·•"))
        return text.isEmpty ? (site ?? "") : text
    }

    /// Whether a title looks like an advertisement rather than the content.
    ///
    /// Deliberately narrow. Guessing wrongly here relabels somebody's music as
    /// an advert, so only the unambiguous markers count.
    static func looksLikeAdvertisement(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return lowered.hasPrefix("ad ") || lowered == "ad"
            || lowered.hasPrefix("advertisement")
    }
}

/// Parses the page's answer back into `PageMedia`.
///
/// Kept separate from the AppleScript that produced it so every shape — a page
/// with no media element, an ended one, a livestream, a malformed reply — can
/// be tested against a fixture instead of against a running browser.
nonisolated extension BrowserMediaParser {
    /// Format: `paused|ended|muted|position|duration`, duration -1 when not
    /// finite. An empty string means the page had no media element this code
    /// could reach, which is different from having a paused one.
    static func parsePageMedia(_ raw: String) -> PageMedia? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 5,
              let paused = Int(parts[0]), let ended = Int(parts[1]),
              let muted = Int(parts[2]),
              let position = Double(parts[3]), let duration = Double(parts[4]),
              position.isFinite
        else { return nil }
        return PageMedia(
            isPaused: paused != 0,
            isEnded: ended != 0,
            isMuted: muted != 0,
            position: max(0, position),
            duration: duration.isFinite && duration > 0 ? duration : nil
        )
    }
}

/// Holds "the browser is emitting audio" true for a moment after it goes false.
///
/// A gap in output is not a stop: a track boundary, a buffer stall, or a silent
/// passage all drop `kAudioProcessPropertyIsRunningOutput` briefly. Without
/// this the widget would blink out and back on its own.
///
/// Bounded on purpose, and short. This is a debounce, not a memory — after the
/// window the answer becomes false and the widget clears, rather than keeping a
/// title on screen that stopped being true.
nonisolated struct BrowserAudioHold: Sendable {
    /// Long enough to ride out a track change, short enough that a pause shows
    /// up as one within a couple of polls.
    static let window: TimeInterval = 3

    private var lastActive: Date?

    init() {}

    /// Records this poll's observation and returns the debounced answer.
    mutating func observe(_ active: Bool, now: Date = Date()) -> Bool {
        if active {
            lastActive = now
            return true
        }
        guard let lastActive else { return false }
        // A clock that went backwards must not extend the hold forever.
        let elapsed = now.timeIntervalSince(lastActive)
        if elapsed >= 0, elapsed < Self.window { return true }
        self.lastActive = nil
        return false
    }

    /// Forgets everything. Used when the browser quits or the tab list empties,
    /// where the debounce would only be holding on to something already gone.
    mutating func reset() { lastActive = nil }
}

/// Turns what was observed into what may honestly be shown.
///
/// A pure function over the observations, deliberately: every case in the
/// matrix — two tabs with one playing, an unrelated tab making noise, a paused
/// video while another plays, muted playback, buffering, an ended video, page
/// access unavailable, the selected tab closing — is decided here and can be
/// tested here, with no browser, no audio, and no permission involved.
nonisolated enum BrowserPlaybackResolver {
    struct Resolution: Equatable, Sendable {
        var title: String
        var subtitle: String
        var state: PlaybackState
        var isAmbiguous: Bool
        /// Which tab this describes, empty when it describes the browser.
        var tabKey: String
        var position: Double
        var duration: Double
        var durationIsUnknown: Bool
        var capabilities: MediaCapabilities
    }

    /// Nil means "say nothing", which is the right answer more often than it
    /// looks. No audio and no page access is not evidence of a pause; it is an
    /// absence of evidence, and a widget that shows a paused title on that
    /// basis is inventing the pause.
    static func resolve(
        tabs: [BrowserMediaTab],
        audioActive: Bool,
        browserName: String,
        incumbentTabKey: String?
    ) -> Resolution? {
        let readable = tabs.filter { $0.page != nil }
        let unreadable = tabs.count - readable.count

        if !readable.isEmpty {
            // The page's own answer, which is the only one that names a tab.
            let playing = readable.filter { $0.page?.isPlaying == true }
            if let tab = pick(playing, incumbent: incumbentTabKey) {
                return named(tab, state: .playing)
            }

            // Nothing readable is playing. If every media tab was readable, then
            // "paused" is a fact about all of them and worth showing — even if
            // the browser is making noise, which then belongs to some tab that
            // is not a player. If some tab could not be read, that tab may be
            // the one playing, so no paused claim is made about the others.
            if unreadable == 0 || !audioActive {
                let paused = readable.filter { $0.page?.isPausedMidway == true }
                if let tab = pick(paused, incumbent: incumbentTabKey) {
                    return named(tab, state: .paused)
                }
                // Everything is ended or was never started. With no audio there
                // is nothing to report at all.
                if !audioActive { return nil }
            }
        }

        // Tier 1. Audio is the only signal, and it belongs to the browser.
        guard audioActive else { return nil }
        guard !tabs.isEmpty else { return nil }
        if tabs.count == 1 { return named(tabs[0], state: .unknown) }
        return Resolution(
            title: "Browser audio active",
            subtitle: "\(browserName) · \(tabs.count) media tabs",
            state: .unknown,
            isAmbiguous: true,
            tabKey: "",
            position: 0,
            duration: 0,
            durationIsUnknown: true,
            capabilities: .titleOnly
        )
    }

    /// Keeps the tab already on screen when it is still a valid answer, so the
    /// widget does not swap between two equally playing tabs on alternate polls.
    private static func pick(
        _ candidates: [BrowserMediaTab], incumbent: String?
    ) -> BrowserMediaTab? {
        if let incumbent, let held = candidates.first(where: { $0.key == incumbent }) {
            return held
        }
        return candidates.first
    }

    private static func named(_ tab: BrowserMediaTab, state: PlaybackState) -> Resolution {
        let advert = BrowserMediaParser.looksLikeAdvertisement(tab.title)
        // The site, not a guessed artist. A YouTube title is not reliably
        // "Artist - Track", and splitting on a hyphen would invent an
        // attribution that is wrong more often than it is right.
        let subtitle = advert ? "Advertisement · \(tab.site)" : tab.site

        var capabilities: MediaCapabilities = .titleOnly
        var position = 0.0
        var duration = 0.0
        var durationUnknown = true

        // Capabilities follow the state, not the channel. A tab can be readable
        // and still end up `.unknown` — page access reached it, its media
        // element was ended, and the noise is coming from somewhere else — and
        // in that case there is no authoritative state to advertise and no
        // sensible icon for a play/pause button to show.
        if let page = tab.page, state.isDefinite {
            capabilities.formUnion([.playbackState, .playPause])
            position = page.position
            if let known = page.duration {
                capabilities.formUnion([.position, .seek])
                duration = known
                durationUnknown = false
            }
        }

        return Resolution(
            title: tab.title,
            subtitle: subtitle,
            state: state,
            isAmbiguous: false,
            tabKey: tab.key,
            position: position,
            duration: duration,
            durationIsUnknown: durationUnknown,
            capabilities: capabilities
        )
    }
}
