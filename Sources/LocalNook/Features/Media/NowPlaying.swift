//
//  NowPlaying.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import AppKit
import Foundation

nonisolated enum PlaybackState: String, Sendable {
    case playing, paused, stopped
    /// Something is audible but nothing has said what, or whether *this* is it.
    ///
    /// Only a browser produces this. Neither Chrome's nor Safari's scripting
    /// dictionary has any per-tab audio or playback property — Chrome's `tab`
    /// class is `id`, `title`, `URL`, `loading`; Safari's is `source`, `URL`,
    /// `index`, `text`, `visible`, `name` — and CoreAudio attributes output to
    /// a *process*, which in Chrome is one shared `audio.mojom.AudioService`
    /// utility for every tab at once. So without page access there is no signal
    /// anywhere that says which tab the sound is coming from. Saying "Playing"
    /// then would be a guess wearing the clothes of a fact.
    case unknown

    var isActive: Bool { self != .stopped }

    /// Whether the source itself told us this, as opposed to it being inferred
    /// from the browser making a noise.
    var isDefinite: Bool { self != .unknown }
}

/// What a source can actually do, as opposed to what it can be asked to do.
///
/// Receiving metadata does not imply being able to control playback, and the
/// two must not be conflated. A browser tab read through the public scripting
/// dictionary yields a title and nothing else: no position, no artwork, and no
/// way to pause it. Showing a pause button there would produce a control that
/// silently does nothing, which is worse than showing no control.
nonisolated struct MediaCapabilities: OptionSet, Equatable, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    /// The source reports whether it is playing or paused, authoritatively.
    static let playbackState = MediaCapabilities(rawValue: 1 << 0)
    /// Position and duration are available, so a scrubber means something.
    static let position      = MediaCapabilities(rawValue: 1 << 1)
    static let artwork       = MediaCapabilities(rawValue: 1 << 2)
    static let playPause     = MediaCapabilities(rawValue: 1 << 3)
    static let skip          = MediaCapabilities(rawValue: 1 << 4)
    static let seek          = MediaCapabilities(rawValue: 1 << 5)

    /// A scripted media app: everything works.
    static let full: MediaCapabilities = [
        .playbackState, .position, .artwork, .playPause, .skip, .seek
    ]
    /// A browser tab known only by its title, with no page access.
    ///
    /// Empty on purpose, `playbackState` included: the browser is emitting
    /// audio, which is not the same as this tab playing. The state travels as
    /// `.unknown` and the UI says so in words rather than claiming otherwise.
    static let titleOnly: MediaCapabilities = []
}

/// A snapshot of what a media app is playing.
nonisolated struct NowPlaying: Equatable, Sendable {
    var sourceID: String
    var sourceName: String
    var state: PlaybackState
    var title: String
    var artist: String
    var album: String
    /// Seconds.
    var duration: Double
    /// Seconds, as of `positionSampledAt`.
    var position: Double
    var positionSampledAt: Date
    var artworkKey: String
    /// What this particular source supports. The UI offers nothing outside it.
    var capabilities: MediaCapabilities = .full
    /// Set when the duration is genuinely unknown rather than zero — a
    /// livestream, or a video whose metadata has not loaded. A progress bar
    /// must not be drawn at 0% for something that has no end.
    var durationIsUnknown = false
    /// Set when more than one candidate could be the source and nothing
    /// distinguishes them. The title then names the browser rather than a tab,
    /// because naming one of several would be picking at random.
    var sourceIsAmbiguous = false

    static let idle = NowPlaying(
        sourceID: "", sourceName: "", state: .stopped, title: "", artist: "",
        album: "", duration: 0, position: 0, positionSampledAt: .distantPast,
        artworkKey: "", capabilities: []
    )

    var isIdle: Bool { state == .stopped || title.isEmpty }

    /// What to tell the reader about playback, in words that are true.
    ///
    /// The `.unknown` cases are the whole point of this property. "Browser
    /// audio active" is a statement about the browser; "Playing" would be a
    /// statement about the tab, and only page access can support that one.
    var statusText: String {
        switch state {
        case .playing: "Playing"
        case .paused: "Paused"
        case .stopped: "Not playing"
        case .unknown: sourceIsAmbiguous ? "Source tab unknown" : "Browser audio active"
        }
    }

    var statusSymbol: String {
        switch state {
        case .playing: "speaker.wave.2.fill"
        case .paused: "pause.fill"
        case .stopped: "stop.fill"
        case .unknown: sourceIsAmbiguous ? "questionmark.circle" : "speaker.wave.2.fill"
        }
    }

    /// Whether anything is moving, for the animated level meter. True for
    /// `.unknown` because audio genuinely *is* coming out of the browser —
    /// that much is measured; only its tab is in doubt.
    var showsMotion: Bool { state == .playing || state == .unknown }

    /// Position advanced to *now*, so the scrubber moves smoothly between the
    /// once-a-second polls instead of stepping.
    var interpolatedPosition: Double {
        let base = position.isFinite ? max(0, position) : 0
        let elapsed = state == .playing ? max(0, Date().timeIntervalSince(positionSampledAt)) : 0
        let upper = duration.isFinite && duration > 0 ? duration : Double.greatestFiniteMagnitude
        return min(upper, base + elapsed)
    }

    var progress: Double {
        guard duration > 0, !durationIsUnknown else { return 0 }
        return min(1, max(0, interpolatedPosition / duration))
    }

    /// Whether a progress bar can honestly be drawn. A livestream has no end,
    /// and an advertisement's duration belongs to the advert rather than to the
    /// thing the person is waiting for.
    var showsProgress: Bool {
        capabilities.contains(.position) && !durationIsUnknown && duration > 0
    }

    /// Identity of the *track*, used to avoid refetching artwork every poll.
    var trackIdentity: String { "\(sourceID)|\(title)|\(artist)|\(album)" }
}

/// A source LocalNook can read playback from and send transport commands to.
protocol MediaProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var bundleID: String { get }

    /// Installed *and* running. Providers must never launch their app.
    var isAvailable: Bool { get }

    func fetch() async -> NowPlaying?
    func playPause() async
    func next() async
    func previous() async
    func seek(to seconds: Double) async
    func artwork(for snapshot: NowPlaying) async -> NSImage?
}

extension MediaProvider {
    /// Installed, running, and permitted.
    ///
    /// The consent check is read-only and cannot prompt, which is the point:
    /// every provider consults it before sending an Apple Event, so no amount
    /// of polling — and no dashboard opening — can produce a dialog. Consent is
    /// asked for by pressing Connect, and by nothing else.
    ///
    /// The consequence for a source that has never been connected is that it
    /// reports nothing rather than raising a prompt at the moment of use. The
    /// widget says which source that is and offers to connect it.
    var isAvailable: Bool {
        MediaScriptBridge.isInstalled(bundleID: bundleID)
            && MediaScriptBridge.isRunning(bundleID: bundleID)
            && AutomationPermission.status(forBundleID: bundleID).isGranted
    }
}

/// Escapes a string for safe interpolation into AppleScript source.
nonisolated func appleScriptEscaped(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
}
