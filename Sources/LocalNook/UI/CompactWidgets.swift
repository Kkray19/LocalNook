//
//  CompactWidgets.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Dashboard-sized presentations of the existing managers. These are purpose-
//  built for a short, wide column — not the full-size views squeezed down.
//

import AppKit
import Combine
import EventKit
import SwiftUI

// MARK: - Media

struct CompactMediaView: View {
    @ObservedObject private var media = MediaManager.shared
    @EnvironmentObject var settings: Settings

    /// Redraw cadence for the progress line while playing.
    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    @LNState private var tick = Date()

    var body: some View {
        Group {
            if media.automationDenied {
                CompactMessage(
                    symbol: "hand.raised.fill",
                    title: "Automation is off",
                    detail: "Allow LocalNook to control Music and Spotify.",
                    actionTitle: "Open Settings"
                ) { Permissions.shared.open(.automation) }
            } else if media.nowPlaying.isIdle {
                CompactMessage(
                    symbol: "play.slash",
                    title: media.hasAnyRunningSource ? "Nothing playing" : "No media app running",
                    detail: media.hasAnyRunningSource ? nil : "Open Music or Spotify."
                )
            } else {
                player
            }
        }
        .onReceive(ticker) { now in
            if media.nowPlaying.state == .playing { tick = now }
        }
    }

    private var player: some View {
        let track = media.nowPlaying
        return VStack(alignment: .leading, spacing: 7) {
            // Artwork and text form one block: the transport sits directly under
            // the artist line, inside the artwork's height, rather than drifting
            // to the bottom of the column.
            HStack(alignment: .top, spacing: 11) {
                artwork(for: track)

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(Theme.title)
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    if !track.album.isEmpty {
                        Text(track.album)
                            .font(Theme.subtitle)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    Text(track.artist.isEmpty ? track.sourceName : track.artist)
                        .font(Theme.subtitle)
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)

                    Spacer(minLength: 2)

                    transport
                        .padding(.bottom, 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 76)

            progress(for: track)
            Spacer(minLength: 0)
        }
    }

    private func artwork(for track: NowPlaying) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = media.artwork, settings.mediaShowArtwork {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    // Deterministic, generated locally. LocalNook makes no
                    // network requests, so this is honest fallback art rather
                    // than a fetched cover.
                    GeneratedArtwork(seed: track.trackIdentity, symbol: "music.note")
                }
            }
            .frame(width: 74, height: 74)
            .clipShape(RoundedRectangle(cornerRadius: Theme.artworkRadius, style: .continuous))

            // Which app the track is coming from.
            Image(systemName: track.sourceID == "spotify" ? "music.note" : "music.note.list")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(Circle().fill(Color.black.opacity(0.75)))
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.5))
                .offset(x: 5, y: 5)
        }
        .onTapGesture { media.revealSource() }
        .help("Open \(track.sourceName)")
    }

    /// See MediaWidgetView.transport — controls appear only where the source
    /// supports them.
    private var transport: some View {
        let capabilities = media.nowPlaying.capabilities
        return HStack(spacing: 13) {
            if capabilities.contains(.skip) {
                TransportControl(symbol: "backward.fill", size: 12) { media.previous() }
            }
            if capabilities.contains(.playPause) {
                TransportControl(
                    symbol: media.nowPlaying.state == .playing ? "pause.fill" : "play.fill",
                    size: 15
                ) { media.playPause() }
            }
            if capabilities.contains(.skip) {
                TransportControl(symbol: "forward.fill", size: 12) { media.next() }
            }
            if !capabilities.contains(.playPause) {
                Text(media.nowPlaying.state == .playing ? "Playing" : "Paused")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
            PlayingIndicator(isPlaying: media.nowPlaying.state == .playing)
        }
    }

    @ViewBuilder
    private func progress(for track: NowPlaying) -> some View {
        // A livestream has no end and an unknown duration is not zero, so
        // neither gets a bar that would sit at 0% and look stuck.
        if track.showsProgress {
            VStack(spacing: 2) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.14))
                        Capsule().fill(.white.opacity(0.80))
                            .frame(width: max(0, geometry.size.width * track.progress))
                    }
                }
                .frame(height: 3)

                HStack {
                    Text(Self.time(track.interpolatedPosition))
                    Spacer()
                    Text(Self.time(track.duration))
                }
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.quaternaryText)
            }
        }
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct TransportControl: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    @LNState private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isHovering ? Theme.primaryText : Theme.primaryText.opacity(0.78))
                .frame(width: size + 8, height: size + 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(NotchMotion.quick) { isHovering = hovering } }
    }
}

/// Decorative "audio is playing" glyph.
///
/// Deliberately **not** a level meter: LocalNook does not tap the audio stream,
/// and animating bars to arbitrary heights would imply a measurement that is not
/// being made. This is a static waveform that simply dims when paused.
private struct PlayingIndicator: View {
    let isPlaying: Bool

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isPlaying ? Theme.secondaryText : Theme.quaternaryText)
            .animation(NotchMotion.content, value: isPlaying)
            .help(isPlaying ? "Playing" : "Paused")
    }
}

// MARK: - Calendar

struct CompactCalendarView: View {
    @ObservedObject private var calendar = CalendarManager.shared

    private var today: Date { Date() }

    var body: some View {
        Group {
            if calendar.isDenied {
                CompactMessage(
                    symbol: "calendar.badge.exclamationmark",
                    title: "Calendar access is off",
                    actionTitle: "Open Settings"
                ) { Permissions.shared.open(.calendar) }
            } else if !calendar.hasAccess {
                // Deliberately an explicit action. Merely opening the notch must
                // never trigger a system permission prompt.
                CompactMessage(
                    symbol: "calendar",
                    title: "Show your events",
                    detail: "Read on this Mac only.",
                    actionTitle: "Allow access"
                ) { calendar.requestAccess() }
            } else {
                content
            }
        }
        // No `activate()` here: that would prompt for consent just because the
        // pointer opened the notch. Access is requested by the button above.
        .onAppear { calendar.refreshIfAuthorized() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(today.formatted(.dateTime.month(.abbreviated)))
                    .font(Theme.display)
                    .foregroundStyle(Theme.primaryText)
                weekStrip
            }
            Divider().overlay(Theme.divider).padding(.vertical, 1)
            upcoming
        }
    }

    private var weekStrip: some View {
        let cal = Foundation.Calendar.current
        let start = cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: today)) ?? today
        return HStack(spacing: 7) {
            ForEach(0..<6, id: \.self) { offset in
                let day = cal.date(byAdding: .day, value: offset, to: start) ?? today
                let isToday = cal.isDateInToday(day)
                let weekday = cal.component(.weekday, from: day)
                let isWeekend = weekday == 1 || weekday == 7
                VStack(spacing: 1) {
                    Text(day.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(isToday ? Theme.accent : Theme.quaternaryText)
                    Text("\(cal.component(.day, from: day))")
                        .font(.system(size: 12, weight: isToday ? .bold : .medium))
                        .monospacedDigit()
                        .foregroundStyle(
                            isToday ? Theme.accent
                                : (isWeekend ? Theme.weekend.opacity(0.75) : Theme.secondaryText)
                        )
                }
            }
        }
    }

    @ViewBuilder
    private var upcoming: some View {
        if let event = calendar.upcoming {
            Button { calendar.open(event) } label: {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(eventTint(event))
                        .frame(width: 2.5, height: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(event.title ?? "Untitled")
                            .font(Theme.body)
                            .foregroundStyle(Theme.primaryText)
                            .lineLimit(1)
                        Text(eventTime(event))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.quaternaryText)
                Text("Nothing scheduled today")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
                Spacer(minLength: 0)
            }
        }
    }

    private func eventTint(_ event: EKEvent) -> Color {
        event.calendar.map { Color(cgColor: $0.cgColor) } ?? Theme.accent
    }

    private func eventTime(_ event: EKEvent) -> String {
        guard let start = event.startDate else { return "" }
        if event.isAllDay { return "All day" }
        return start.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Timer

struct CompactTimerView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject private var timers = TimerManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(timers.mode == .pomodoro ? timers.pomodoroPhase.label : timers.mode.label)
                .font(Theme.sectionTitle)
                .foregroundStyle(Theme.tertiaryText)
                .textCase(.uppercase)
            Text(timers.formatted)
                .font(Theme.display)
                .monospacedDigit()
                .foregroundStyle(Theme.primaryText)
            HStack(spacing: 7) {
                Button(action: timers.toggle) {
                    Image(systemName: timers.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 20)
                        .background(Capsule().fill(Theme.surfaceHover))
                        .foregroundStyle(Theme.primaryText)
                }
                .buttonStyle(.plain)
                Button(action: timers.reset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 20)
                        .background(Capsule().fill(Theme.surface))
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Stats

struct CompactStatsView: View {
    @ObservedObject private var battery = BatteryMonitor.shared
    private let ticker = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Battery")
                .font(Theme.sectionTitle)
                .foregroundStyle(Theme.tertiaryText)
                .textCase(.uppercase)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(battery.state.isPresent ? "\(battery.state.percentage)" : "—")
                    .font(Theme.display)
                    .monospacedDigit()
                    .foregroundStyle(Theme.primaryText)
                Text("%").font(Theme.subtitle).foregroundStyle(Theme.tertiaryText)
                if battery.state.isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.positive)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(battery.state.tint.opacity(0.9))
                        .frame(width: geometry.size.width * CGFloat(battery.state.percentage) / 100)
                }
            }
            .frame(height: 3)
            Text(detail)
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .onAppear { battery.refresh() }
        .onReceive(ticker) { _ in battery.refresh() }
    }

    private var detail: String {
        let state = battery.state
        guard state.isPresent else { return "No battery" }
        if state.isCharging { return state.timeLabel.map { "\($0) to full" } ?? "Charging" }
        if state.isPluggedIn { return "Plugged in" }
        return state.timeLabel.map { "\($0) left" } ?? "On battery"
    }
}

// MARK: - Sessions

struct CompactSessionsView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject private var monitor = SessionMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(monitor.hasActivity ? Theme.positive : Theme.quaternaryText)
                    .frame(width: 5, height: 5)
                Text("AI Sessions")
                    .font(Theme.sectionTitle)
                    .foregroundStyle(Theme.tertiaryText)
                    .textCase(.uppercase)
            }
            if monitor.sessions.isEmpty {
                Text("None recently")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                ForEach(monitor.sessions.prefix(3)) { session in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: session.agent.symbol)
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.quaternaryText)
                            .frame(width: 11)
                        VStack(alignment: .leading, spacing: 1) {
                            // The chat's own name where there is one; the
                            // directory only as a fallback.
                            Text(session.displayName)
                                .font(Theme.caption)
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                            if session.detail.showsProgress, let step = session.detail.step {
                                HStack(spacing: 4) {
                                    SessionWorkingBar()
                                    Text(step)
                                        .font(.system(size: 9))
                                        .foregroundStyle(Theme.quaternaryText)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            } else if let model = session.detail.modelLabel {
                                Text(model)
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.quaternaryText)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        Text(session.relativeActivity)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.quaternaryText)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .onAppear { monitor.start() }
    }
}

/// The marching bar shown beside a session's current step, matching the
/// progress line the agents show while they are working. Decorative: it says
/// "still going", not how far along.
struct SessionWorkingBar: View {
    @LNState private var shift: CGFloat = -1

    var body: some View {
        Capsule()
            .fill(Theme.quaternaryText.opacity(0.4))
            .frame(width: 14, height: 2.5)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(Theme.positive)
                        .frame(width: geometry.size.width * 0.45)
                        .offset(x: shift * geometry.size.width * 0.62)
                }
            }
            .clipShape(Capsule())
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    shift = 1
                }
            }
    }
}
