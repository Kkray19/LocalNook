//
//  LiveActivityCenter.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Turns system events into the short-lived pills that appear beside the closed
//  notch. Everything is push-driven — this class subscribes to notifications and
//  publishers, and never polls.
//

import AppKit
import Combine
import SwiftUI

/// One thing worth flashing beside the notch.
/// One line of the expanded trailing indicator: which session, and what it is
/// doing. Only ever built from fields the sessions reader was allowed to read.
struct LiveActivityDetail: Identifiable, Equatable {
    let id: String
    var symbol: String
    var name: String
    var step: String
}

struct LiveActivity: Identifiable, Equatable {
    enum Style: Equatable {
        /// A short banner that fades away by itself.
        case transient
        /// Stays as long as its underlying state holds (media, a running timer).
        case persistent
    }

    let id: String
    var symbol: String
    var tint: Color
    /// Shown to the left of the notch.
    var leading: String
    /// Shown to the right of the notch.
    var trailing: String
    var style: Style
    /// 0…1 for a progress ring, when relevant.
    var progress: Double?
    var priority: Int
    /// Something is mid-task. The trailing side shows a running indicator
    /// rather than naming the task: what an agent is working on is the part
    /// someone may not want sitting on their menu bar, and a spinner says
    /// "working" without saying what about.
    var isBusy = false
    /// What that indicator expands to when the pointer rests on it. Empty when
    /// there is nothing to add beyond `trailing`.
    var details: [LiveActivityDetail] = []
}

final class LiveActivityCenter: ObservableObject {
    static let shared = LiveActivityCenter()

    /// The activity currently on screen, if any.
    @Published private(set) var current: LiveActivity?
    /// The pointer is resting on the trailing indicator. Driven by the
    /// controller, which is the only thing that knows where the wings are
    /// drawn on screen.
    @Published private(set) var trailingExpanded = false

    private var transient: LiveActivity?
    private var dismissTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private let settings = Settings.shared

    private init() {}

    func start() {
        guard cancellables.isEmpty else { return }
        settings.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.transient = nil
                self?.recompute()
            }.store(in: &cancellables)
        subscribeToSystemEvents()
        observeContinuousSources()
    }

    // MARK: Transient events

    private func subscribeToSystemEvents() {
        let center = NotificationCenter.default

        observe(center, .powerConnected, as: BatteryState.self) { [weak self] state in
            self?.show(LiveActivity(
                id: "power.connected", symbol: "powerplug.fill", tint: .green,
                leading: "Charging", trailing: "\(state.percentage)%",
                style: .transient, progress: Double(state.percentage) / 100, priority: 60
            ), enabled: self?.settings.activityCharging ?? false)
        }

        observe(center, .powerDisconnected, as: BatteryState.self) { [weak self] state in
            self?.show(LiveActivity(
                id: "power.disconnected", symbol: "battery.50percent", tint: .white,
                leading: "On battery", trailing: state.timeLabel ?? "\(state.percentage)%",
                style: .transient, progress: Double(state.percentage) / 100, priority: 60
            ), enabled: self?.settings.activityCharging ?? false)
        }

        observe(center, .batteryFull) { [weak self] in
            self?.show(LiveActivity(
                id: "battery.full", symbol: "battery.100percent.bolt", tint: .green,
                leading: "Fully charged", trailing: "100%",
                style: .transient, progress: 1, priority: 65
            ), enabled: self?.settings.activityBattery ?? false)
        }

        observe(center, .batteryLow, as: BatteryState.self) { [weak self] state in
            self?.show(LiveActivity(
                id: "battery.low", symbol: "battery.25percent", tint: .orange,
                leading: "Battery low", trailing: "\(state.percentage)%",
                style: .transient, progress: Double(state.percentage) / 100, priority: 80
            ), enabled: self?.settings.activityBattery ?? false)
        }

        observe(center, .audioOutputChanged, as: AudioOutputChange.self) { [weak self] change in
            self?.show(LiveActivity(
                id: "audio.changed",
                symbol: change.isWireless ? "airpods.pro" : "hifispeaker.fill",
                tint: .white,
                leading: change.isWireless ? "Connected" : "Output",
                trailing: change.name,
                style: .transient, progress: nil, priority: 55
            ), enabled: self?.settings.activityBluetooth ?? false)
        }

        observe(center, .timerCompleted) { [weak self] in
            self?.show(LiveActivity(
                id: "timer.done", symbol: "timer", tint: .accentColor,
                leading: "Time's up", trailing: "", style: .transient,
                progress: nil, priority: 90
            ), enabled: self?.settings.activityTimer ?? false)
        }

        observe(center, .agentSessionWentIdle, as: AgentSession.self) { [weak self] session in
            self?.show(LiveActivity(
                id: "session.idle", symbol: session.agent.symbol, tint: .orange,
                leading: session.agent.label, trailing: "went quiet",
                style: .transient, progress: nil, priority: 70
            ), enabled: self?.settings.activitySessions ?? false)
        }
    }

    /// Subscribes to a notification and hands the handler a typed, `Sendable`
    /// payload. `Notification` itself is not `Sendable`, so it is unpacked at
    /// the boundary rather than carried across it.
    private func observe<Payload: Sendable>(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        as _: Payload.Type,
        _ handler: @escaping @MainActor (Payload) -> Void
    ) {
        center.addObserver(forName: name, object: nil, queue: .main) { note in
            guard let payload = note.object as? Payload else { return }
            MainActor.assumeIsolated { handler(payload) }
        }
    }

    /// Variant for notifications that carry nothing.
    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ handler: @escaping @MainActor () -> Void
    ) {
        center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    private func show(_ activity: LiveActivity, enabled: Bool) {
        guard enabled, transient != activity else { return }
        // A more urgent banner replaces a less urgent one already on screen.
        if let existing = transient, existing.priority > activity.priority { return }
        transient = activity
        recompute()

        dismissTask?.cancel()
        let duration = settings.activityDuration
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.transient = nil
            self?.recompute()
        }
    }

    // MARK: Persistent sources

    /// Media and timers stay visible for as long as they are running.
    private func observeContinuousSources() {
        MediaManager.shared.$nowPlaying
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)

        TimerManager.shared.$displayed
            .map { _ in () }
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.recompute() }
            .store(in: &cancellables)

        SessionMonitor.shared.$sessions
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
    }

    private var persistentActivity: LiveActivity? {
        let timers = TimerManager.shared
        if settings.activityTimer, timers.isRunning {
            return LiveActivity(
                id: "timer.running", symbol: "timer", tint: .accentColor,
                leading: timers.mode == .pomodoro ? timers.pomodoroPhase.label : "Timer",
                trailing: timers.formatted,
                style: .persistent,
                progress: timers.totalDuration.map { _ in 1 - timers.progress },
                priority: 50
            )
        }

        let media = MediaManager.shared.nowPlaying
        if settings.activityMedia, media.state == .playing {
            return LiveActivity(
                id: "media.playing", symbol: "waveform", tint: .white,
                leading: media.title, trailing: media.artist,
                style: .persistent, progress: media.progress, priority: 40
            )
        }

        let active = SessionMonitor.shared.activeSessions
        if settings.activitySessions, !active.isEmpty {
            // The model rather than the directory, when the reader was
            // allowed to look. The step only appears while the turn is actually
            // current — a stale tool description must not read as "working on
            // this right now". Everything falls back to the metadata-only
            // presentation, which is also what a locked screen gets, because
            // the reader declines to read at all while locked.
            let leading: String
            if active.count == 1 {
                leading = active[0].detail.modelLabel ?? active[0].displayName
            } else {
                let models = Set(active.compactMap(\.detail.model))
                leading = models.count == 1
                    ? "\(active.count) × \(models.first!)"
                    : "\(active.count) agents"
            }

            // The badge is about the maker, not the count. Everything running
            // is Claude, or everything is OpenAI, and it says so; a mix falls
            // back to the generic mark because no single one would be true.
            let badge = Self.badge(for: active)

            // "Working" means a turn is genuinely in flight and the transcript
            // says so — the same bar the widget uses for its own indicator.
            let working = active.filter(\.detail.showsProgress)
            let trailing: String
            if working.isEmpty {
                trailing = active.count == 1 ? active[0].relativeActivity : "active recently"
            } else {
                // Deliberately empty: the spinner is the message.
                trailing = ""
            }

            return LiveActivity(
                id: "sessions.active",
                symbol: badge.symbol,
                tint: badge.tint,
                leading: leading, trailing: trailing,
                style: .persistent, progress: nil, priority: 30,
                isBusy: !working.isEmpty,
                details: Self.details(for: active)
            )
        }

        return nil
    }

    /// Which mark to show for a set of running sessions.
    ///
    /// The badge is about the maker, not the count: everything running is
    /// Claude, or everything is OpenAI, and it says so. A mix falls back to the
    /// generic mark, because no single maker's mark would be true of it.
    static func badge(for sessions: [AgentSession]) -> (symbol: String, tint: Color) {
        let providers = Set(sessions.map(\.agent.provider))
        guard providers.count == 1, let only = providers.first else {
            return (SessionProvider.mixedSymbol, .green)
        }
        return (only.symbol, tint(for: only))
    }

    /// Brand-ish colours, which are not the same thing as brand artwork: a hue
    /// distinguishes the two makers without bundling anyone's mark.
    static func tint(for provider: SessionProvider) -> Color {
        switch provider {
        case .anthropic: Color(red: 0.85, green: 0.47, blue: 0.30)
        case .openAI: Color(red: 0.29, green: 0.78, blue: 0.66)
        }
    }

    /// One line per session, newest first, capped.
    ///
    /// A session with no step contributes when it happened instead, so the
    /// expansion is never a list of names with nothing beside them.
    static func details(for sessions: [AgentSession]) -> [LiveActivityDetail] {
        sessions.prefix(4).map { session in
            LiveActivityDetail(
                id: session.id,
                symbol: session.agent.symbol,
                name: session.displayName,
                step: session.detail.step ?? session.relativeActivity
            )
        }
    }

    /// Set from the controller's pointer poll. Refuses to expand an activity
    /// that has nothing to expand into, so the width can never grow for an
    /// indicator that would show a blank strip.
    func setTrailingExpanded(_ expanded: Bool) {
        let allowed = expanded && current.map(ClosedActivityView.canExpand) == true
        guard allowed != trailingExpanded else { return }
        withAnimation(NotchMotion.quick) { trailingExpanded = allowed }
    }

    /// Used only by `--render-preview` to stage an activity for a screenshot.
    func previewInject(_ activity: LiveActivity?) {
        transient = activity
        current = activity
    }

    private func recompute() {
        let resolved = transient ?? persistentActivity
        guard resolved != current else { return }
        withAnimation(NotchMotion.quick) { current = resolved }
    }
}
