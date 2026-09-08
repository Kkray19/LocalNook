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

    static let idle = NowPlaying(
        sourceID: "", sourceName: "", state: .stopped, title: "", artist: "",
        album: "", duration: 0, position: 0, positionSampledAt: .distantPast,
        artworkKey: ""
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
        guard duration > 0 else { return 0 }
        return min(1, max(0, interpolatedPosition / duration))
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
func appleScriptEscaped(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
}
