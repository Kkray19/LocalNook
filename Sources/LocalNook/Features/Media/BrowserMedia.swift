//
//  BrowserMedia.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Reading what a browser is playing, without a browser extension.
//
//  ── What is actually possible on macOS 27, established by measurement ──────
//
//  MediaRemote — the private framework that used to expose a system-wide
//  now-playing feed — is entitlement-gated since macOS 15.4. Probed directly on
//  this machine: the framework loads, the symbol resolves, the callback fires,
//  and the payload is nil while QuickTime is confirmed playing. It is therefore
//  not a path for an ordinary application, and no MediaRemote code ships here.
//  The published workarounds (a bundled Perl helper that inherits Apple's own
//  bundle identifier, or code injection with SIP disabled) are a helper install
//  and a security bypass respectively, and are out of scope.
//
//  What remains is two public mechanisms, with genuinely different capability:
//
//    Tier 1 — tab title + audio state.  The browser's scripting dictionary
//    gives the title and URL of every tab, with no JavaScript involved. Public
//    CoreAudio says whether the browser is emitting audio. Together: *what* is
//    playing and *whether* it is playing. No position, no artwork, no controls.
//
//    Tier 2 — page access.  With "Allow JavaScript from Apple Events" switched
//    on by the user, `execute javascript` reaches the page's own media element:
//    exact paused state, position, duration, and working transport controls.
//
//  Tier 2 cannot be enabled programmatically, and should not be: it lets any
//  scripting client run arbitrary JavaScript in every tab. It is offered as an
//  explicit choice with the cost stated, and Tier 1 works without it.
//
//  ── Permissions ────────────────────────────────────────────────────────────
//
//  Reading tabs at all requires Automation consent for that browser, which
//  macOS prompts for on first use. So this whole provider is off until the user
//  turns it on: opening the dashboard must never produce a permission prompt.
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

/// One playing thing found in a browser.
nonisolated struct BrowserMediaTab: Equatable, Sendable {
    var title: String
    var url: String
    var site: String
    /// Present only when page access is available.
    var position: Double?
    var duration: Double?
    var isPaused: Bool?
    var isLive = false
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
