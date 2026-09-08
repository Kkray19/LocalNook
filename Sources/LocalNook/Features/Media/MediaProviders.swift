//
//  MediaProviders.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import AppKit
import Foundation

// MARK: - Apple Music

/// Reads and controls Music.app over Apple Events.
struct MusicAppProvider: MediaProvider {
    let id = "music"
    let displayName = "Music"
    let bundleID = "com.apple.Music"

    /// One round-trip fetches everything; a script per field would be far slower.
    /// `player position` is only valid while a track exists, hence the guard.
    private static let fetchScript = """
    tell application id "com.apple.Music"
        if not running then return ""
        set st to player state as text
        if st is "stopped" then return "stopped"
        try
            set trackName to name of current track
            set trackArtist to artist of current track
            set trackAlbum to album of current track
            set trackDuration to duration of current track
            set trackPosition to player position
        on error
            return "stopped"
        end try
        return st & linefeed & trackName & linefeed & trackArtist & linefeed & \
            trackAlbum & linefeed & (trackDuration as text) & linefeed & (trackPosition as text)
    end tell
    """

    func fetch() async -> NowPlaying? {
        guard isAvailable else { return nil }
        let result = await MediaScriptBridge.shared.run(Self.fetchScript)
        return parseStandard(result, sourceID: id, sourceName: displayName, positionScale: 1)
    }

    func playPause() async { await command("playpause") }
    func next() async { await command("next track") }
    func previous() async { await command("previous track") }

    func seek(to seconds: Double) async {
        await run("set player position to \(String(format: "%.2f", seconds))")
    }

    private func command(_ verb: String) async { await run(verb) }

    private func run(_ body: String) async {
        guard isAvailable else { return }
        _ = await MediaScriptBridge.shared.run("""
        tell application id "com.apple.Music"
            if running then \(body)
        end tell
        return ""
        """)
    }

    /// Music exposes raw artwork bytes, so no network request is needed.
    func artwork(for snapshot: NowPlaying) async -> NSImage? {
        guard isAvailable else { return nil }
        let result = await MediaScriptBridge.shared.run("""
        tell application id "com.apple.Music"
            if not running then return ""
            try
                if (count of artworks of current track) is 0 then return ""
                set art to data of artwork 1 of current track
            on error
                return ""
            end try
        end tell
        return ""
        """)
        // NSAppleScript flattens image data awkwardly; when it is unavailable the
        // UI falls back to a generated placeholder rather than fetching remotely.
        _ = result
        return nil
    }
}

// MARK: - Spotify

/// Reads and controls the Spotify desktop client over Apple Events.
struct SpotifyProvider: MediaProvider {
    let id = "spotify"
    let displayName = "Spotify"
    let bundleID = "com.spotify.client"

    /// Spotify reports duration in **milliseconds** and position in seconds.
    private static let fetchScript = """
    tell application id "com.spotify.client"
        if not running then return ""
        set st to player state as text
        if st is "stopped" then return "stopped"
        try
            set trackName to name of current track
            set trackArtist to artist of current track
            set trackAlbum to album of current track
            set trackDuration to duration of current track
            set trackPosition to player position
        on error
            return "stopped"
        end try
        return st & linefeed & trackName & linefeed & trackArtist & linefeed & \
            trackAlbum & linefeed & (trackDuration as text) & linefeed & (trackPosition as text)
    end tell
    """

    func fetch() async -> NowPlaying? {
        guard isAvailable else { return nil }
        let result = await MediaScriptBridge.shared.run(Self.fetchScript)
        return parseStandard(result, sourceID: id, sourceName: displayName, positionScale: 0.001)
    }

    func playPause() async { await run("playpause") }
    func next() async { await run("next track") }
    func previous() async { await run("previous track") }

    func seek(to seconds: Double) async {
        await run("set player position to \(String(format: "%.2f", seconds))")
    }

    private func run(_ body: String) async {
        guard isAvailable else { return }
        _ = await MediaScriptBridge.shared.run("""
        tell application id "com.spotify.client"
            if running then \(body)
        end tell
        return ""
        """)
    }

    /// Spotify only exposes artwork as a remote URL. LocalNook does not make
    /// network requests, so the UI shows a generated placeholder instead.
    func artwork(for snapshot: NowPlaying) async -> NSImage? { nil }
}

// MARK: - Shared parsing

/// Parses the six-line payload both providers return.
///
/// `positionScale` converts the app's duration units into seconds (Spotify
/// reports milliseconds, Music reports seconds).
private func parseStandard(
    _ result: ScriptResult,
    sourceID: String,
    sourceName: String,
    positionScale: Double
) -> NowPlaying? {
    guard result.errorNumber == nil else { return nil }
    let lines = result.lines
    guard let first = lines.first, !first.isEmpty else { return nil }
    guard first != "stopped", lines.count >= 6 else {
        return NowPlaying(
            sourceID: sourceID, sourceName: sourceName, state: .stopped,
            title: "", artist: "", album: "", duration: 0, position: 0,
            positionSampledAt: Date(), artworkKey: ""
        )
    }

    let state: PlaybackState = first.lowercased() == "playing" ? .playing : .paused
    let duration = (Double(lines[4].trimmingCharacters(in: .whitespaces)) ?? 0) * positionScale
    let position = Double(lines[5].trimmingCharacters(in: .whitespaces)) ?? 0

    return NowPlaying(
        sourceID: sourceID,
        sourceName: sourceName,
        state: state,
        title: lines[1],
        artist: lines[2],
        album: lines[3],
        duration: max(0, duration),
        position: max(0, position),
        positionSampledAt: Date(),
        artworkKey: "\(sourceID)|\(lines[1])|\(lines[2])"
    )
}
