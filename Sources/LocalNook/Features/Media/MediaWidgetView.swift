//
//  MediaWidgetView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import AppKit
import Combine
import SwiftUI

struct MediaWidgetView: View {
    @ObservedObject private var media = MediaManager.shared
    @EnvironmentObject var settings: Settings

    /// Drives smooth scrubber motion between the once-a-second polls.
    @LNState private var tick = Date()
    @LNState private var scrubFraction: Double?

    private let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if media.automationDenied {
                MediaMessage(
                    symbol: "hand.raised.fill",
                    title: "Automation access is off",
                    detail: "Allow LocalNook to control Music and Spotify in System Settings ▸ Privacy & Security ▸ Automation.",
                    actionTitle: "Open Settings",
                    action: { Permissions.shared.open(.automation) }
                )
            } else if media.nowPlaying.isIdle {
                idle
            } else {
                player
            }
        }
        .onAppear { media.activate() }
        .onReceive(ticker) { now in
            // Only redraw while something is actually moving.
            if media.nowPlaying.state == .playing { tick = now }
        }
    }

    // MARK: Idle

    private var idle: some View {
        MediaMessage(
            symbol: "play.slash",
            title: media.hasAnyRunningSource ? "Nothing playing" : "No media app running",
            detail: media.hasAnyRunningSource
                ? "Start a track in \(media.availableProviders.map(\.displayName).formattedList)."
                : detailForNoApp,
            actionTitle: nil,
            action: nil
        )
    }

    private var detailForNoApp: String {
        let installed = media.installedProviderNames
        return installed.isEmpty
            ? "LocalNook reads playback from Music and Spotify."
            : "Open \(installed.formattedList) and LocalNook will pick it up."
    }

    // MARK: Player

    private var player: some View {
        let track = media.nowPlaying
        return HStack(spacing: 12) {
            if settings.mediaShowArtwork { artwork(for: track) }

            VStack(alignment: .leading, spacing: 0) {
                Text(track.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(track.artist.isEmpty ? track.album : track.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)

                Spacer(minLength: 4)

                scrubber(for: track)

                Spacer(minLength: 4)

                transport
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func artwork(for track: NowPlaying) -> some View {
        Group {
            if let image = media.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                // Deterministic gradient derived from the track, so the same
                // song always looks the same — no network request needed.
                GeneratedArtwork(seed: track.trackIdentity, symbol: sourceSymbol(track))
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
        }
        .onTapGesture { media.revealSource() }
        .help("Open \(track.sourceName)")
    }

    private func sourceSymbol(_ track: NowPlaying) -> String {
        track.sourceID == "spotify" ? "music.note" : "music.note.list"
    }

    private func scrubber(for track: NowPlaying) -> some View {
        let fraction = scrubFraction ?? track.progress
        return VStack(spacing: 3) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule().fill(.white.opacity(0.85))
                        .frame(width: max(0, min(width, width * fraction)))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            scrubFraction = min(1, max(0, value.location.x / width))
                        }
                        .onEnded { value in
                            let target = min(1, max(0, value.location.x / width))
                            scrubFraction = nil
                            media.seek(toFraction: target)
                        }
                )
            }
            .frame(height: 4)

            HStack {
                Text(timeString(fraction * track.duration))
                Spacer()
                Text(timeString(track.duration))
            }
            .font(.system(size: 9, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.45))
        }
    }

    private var transport: some View {
        HStack(spacing: 16) {
            TransportButton(symbol: "backward.fill", size: 12) { media.previous() }
            TransportButton(
                symbol: media.nowPlaying.state == .playing ? "pause.fill" : "play.fill",
                size: 16
            ) { media.playPause() }
            TransportButton(symbol: "forward.fill", size: 12) { media.next() }

            Spacer()

            Text(media.nowPlaying.sourceName)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let secs = total % 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Pieces

private struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void

    @LNState private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isHovering ? .white : .white.opacity(0.75))
                .scaleEffect(isHovering ? 1.12 : 1)
                .frame(width: size + 10, height: size + 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(NotchMotion.quick) { isHovering = hovering }
        }
    }
}

/// Placeholder cover art. LocalNook does not fetch artwork over the network, so
/// this derives a stable colour pair from the track identity instead.
struct GeneratedArtwork: View {
    let seed: String
    let symbol: String

    private var hue: Double {
        // FNV-1a keeps this stable across launches, unlike String.hashValue.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Double(hash % 360) / 360
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.45, brightness: 0.55),
                    Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1),
                          saturation: 0.55, brightness: 0.32),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

private struct MediaMessage: View {
    let symbol: String
    let title: String
    let detail: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.white.opacity(0.4))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.white.opacity(0.14)))
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }
}

extension Array where Element == String {
    /// "Music", "Music and Spotify", "A, B and C".
    var formattedList: String {
        switch count {
        case 0: ""
        case 1: self[0]
        case 2: "\(self[0]) and \(self[1])"
        default: "\(dropLast().joined(separator: ", ")) and \(self[count - 1])"
        }
    }
}
