//
//  TimerManager.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import AppKit
import Combine
import Foundation
import UserNotifications

enum TimerMode: String, CaseIterable, Identifiable {
    case countdown, stopwatch, pomodoro

    var id: String { rawValue }
    var label: String {
        switch self {
        case .countdown: "Timer"
        case .stopwatch: "Stopwatch"
        case .pomodoro: "Pomodoro"
        }
    }
}

enum PomodoroPhase: String {
    case focus, shortBreak, longBreak

    var label: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short break"
        case .longBreak: "Long break"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .focus: 25 * 60
        case .shortBreak: 5 * 60
        case .longBreak: 15 * 60
        }
    }
}

/// Countdown, stopwatch and pomodoro in one place.
///
/// Elapsed time is derived from wall-clock dates rather than counted by the
/// tick, so a timer stays accurate across sleep and across dropped ticks. The
/// tick only drives redraws, and only runs while something is actually running.
final class TimerManager: ObservableObject {
    static let shared = TimerManager()

    @Published var mode: TimerMode = .countdown
    @Published private(set) var isRunning = false
    /// Seconds shown on screen.
    @Published private(set) var displayed: TimeInterval = 0
    @Published private(set) var pomodoroPhase: PomodoroPhase = .focus
    @Published private(set) var completedFocusSessions = 0
    /// Chosen countdown length in seconds.
    @Published var countdownDuration: TimeInterval = 5 * 60

    private var startedAt: Date?
    private var accumulated: TimeInterval = 0
    private var ticker: AnyCancellable?
    private var notificationsRequested = false

    private init() {
        // Show the full countdown straight away rather than 0:00 until first start.
        refreshDisplayed()
    }

    // MARK: Derived state

    /// Total length of the current run, or `nil` for the open-ended stopwatch.
    var totalDuration: TimeInterval? {
        switch mode {
        case .countdown: countdownDuration
        case .pomodoro: pomodoroPhase.duration
        case .stopwatch: nil
        }
    }

    var progress: Double {
        guard let total = totalDuration, total > 0 else { return 0 }
        return min(1, max(0, 1 - displayed / total))
    }

    /// True whenever something should be shown in the collapsed notch.
    var hasActiveSession: Bool { isRunning || accumulated > 0 }

    var formatted: String {
        let value = max(0, displayed)
        let total = Int(value)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: Control

    func start() {
        guard !isRunning else { return }
        if displayed <= 0, mode != .stopwatch { reset() }
        startedAt = Date()
        isRunning = true
        startTicking()
    }

    func pause() {
        guard isRunning, let startedAt else { return }
        accumulated += Date().timeIntervalSince(startedAt)
        self.startedAt = nil
        isRunning = false
        stopTicking()
        refreshDisplayed()
    }

    func toggle() { isRunning ? pause() : start() }

    func reset() {
        stopTicking()
        isRunning = false
        startedAt = nil
        accumulated = 0
        refreshDisplayed()
    }

    func setMode(_ newMode: TimerMode) {
        guard newMode != mode else { return }
        reset()
        mode = newMode
        if newMode == .pomodoro { pomodoroPhase = .focus }
        refreshDisplayed()
    }

    func adjustCountdown(by seconds: TimeInterval) {
        guard mode == .countdown else { return }
        countdownDuration = max(30, min(6 * 3600, countdownDuration + seconds))
        if !isRunning { reset() }
    }

    // MARK: Ticking

    /// One shared 0.2s tick, alive only while something is running. Nothing here
    /// polls when the app is idle.
    private func startTicking() {
        stopTicking()
        ticker = Timer.publish(every: 0.2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshDisplayed() }
        refreshDisplayed()
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }

    private var elapsed: TimeInterval {
        accumulated + (startedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    private func refreshDisplayed() {
        switch mode {
        case .stopwatch:
            displayed = elapsed
        case .countdown:
            displayed = max(0, countdownDuration - elapsed)
            if displayed <= 0, isRunning { complete() }
        case .pomodoro:
            displayed = max(0, pomodoroPhase.duration - elapsed)
            if displayed <= 0, isRunning { complete() }
        }
    }

    // MARK: Completion

    private func complete() {
        stopTicking()
        isRunning = false
        startedAt = nil
        accumulated = 0

        switch mode {
        case .countdown:
            notify(title: "Timer finished", body: "Your \(minutesLabel(countdownDuration)) timer is up.")
            displayed = 0
        case .pomodoro:
            let finished = pomodoroPhase
            if finished == .focus {
                completedFocusSessions += 1
                // Long break after every fourth focus block.
                pomodoroPhase = completedFocusSessions % 4 == 0 ? .longBreak : .shortBreak
            } else {
                pomodoroPhase = .focus
            }
            notify(
                title: "\(finished.label) finished",
                body: "Next up: \(pomodoroPhase.label.lowercased())."
            )
            displayed = pomodoroPhase.duration
        case .stopwatch:
            break
        }

        NotificationCenter.default.post(name: .timerCompleted, object: nil)
        if Settings.shared.hapticFeedback {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    private func minutesLabel(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 1 ? "\(minutes) minute" + (minutes == 1 ? "" : "s") : "\(Int(seconds)) second"
    }

    /// Notification permission is requested the first time a timer completes —
    /// never at launch.
    private func notify(title: String, body: String) {
        // Without a bundle there is no notification centre to talk to.
        guard AppInfo.isRunningFromBundle else {
            NSSound.beep()
            return
        }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        Task {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined, !notificationsRequested {
                notificationsRequested = true
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                Permissions.shared.refreshAll()
            }
            let refreshed = await center.notificationSettings()
            guard refreshed.authorizationStatus == .authorized
                || refreshed.authorizationStatus == .provisional else {
                // Permission refused: fall back to an audible cue rather than
                // failing silently.
                NSSound.beep()
                return
            }
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil
            )
            try? await center.add(request)
        }
    }
}

extension Notification.Name {
    static let timerCompleted = Notification.Name("LocalNook.timerCompleted")
}
