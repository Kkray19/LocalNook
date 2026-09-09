//
//  NowPlaying.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import AppKit
import Foundation

enum PlaybackState: String, Sendable {
    case playing, paused, stopped

    var isActive: Bool { self != .stopped }
}

/// What a source can actually do, as opposed to what it can be asked to do.
///
/// Receiving metadata does not imply being able to control playback, and the
/// two must not be conflated. A browser tab read through the public scripting
/// dictionary yields a title and nothing else: no position, no artwork, and no
/// way to pause it. Showing a pause button there would produce a control that
/// silently does nothing, which is worse than showing no control.
struct MediaCapabilities: OptionSet, Equatable, Sendable {
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
    /// A browser tab identified only by its title, with playback inferred from
    /// whether the app is emitting audio. Enough to say *what* is playing, and
    /// nothing more.
    static let titleOnly: MediaCapabilities = [.playbackState]
}

/// A snapshot of what a media app is playing.
struct NowPlaying: Equatable, Sendable {
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

    static let idle = NowPlaying(
        sourceID: "", sourceName: "", state: .stopped, title: "", artist: "",
        album: "", duration: 0, position: 0, positionSampledAt: .distantPast,
        artworkKey: "", capabilities: []
    )

    var isIdle: Bool { state == .stopped || title.isEmpty }

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
    var isAvailable: Bool {
        MediaScriptBridge.isInstalled(bundleID: bundleID)
            && MediaScriptBridge.isRunning(bundleID: bundleID)
    }
}

/// Escapes a string for safe interpolation into AppleScript source.
nonisolated func appleScriptEscaped(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
}
