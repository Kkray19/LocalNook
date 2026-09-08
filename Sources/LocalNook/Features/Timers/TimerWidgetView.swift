//
//  TimerWidgetView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import SwiftUI

struct TimerWidgetView: View {
    @ObservedObject private var timers = TimerManager.shared

    var body: some View {
        HStack(spacing: 14) {
            dial
            VStack(alignment: .leading, spacing: 8) {
                modePicker
                controls
                if timers.mode == .countdown { presets }
                if timers.mode == .pomodoro { pomodoroStatus }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var dial: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: 5)
            if timers.totalDuration != nil {
                Circle()
                    .trim(from: 0, to: max(0.001, 1 - timers.progress))
                    .stroke(
                        AngularGradient(
                            colors: [.accentColor, .accentColor.opacity(0.6)],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: timers.progress)
            }
            Text(timers.formatted)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .frame(width: 92, height: 92)
    }

    private var modePicker: some View {
        HStack(spacing: 3) {
            ForEach(TimerMode.allCases) { mode in
                let selected = timers.mode == mode
                Button { timers.setMode(mode) } label: {
                    Text(mode.label)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background {
                            Capsule().fill(selected ? Color.white.opacity(0.18) : .clear)
                        }
                        .foregroundStyle(selected ? .white : .white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button(action: timers.toggle) {
                Label(
                    timers.isRunning ? "Pause" : "Start",
                    systemImage: timers.isRunning ? "pause.fill" : "play.fill"
                )
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.16)))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button(action: timers.reset) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(7)
                    .background(Circle().fill(.white.opacity(0.10)))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Reset")
        }
    }

    private var presets: some View {
        HStack(spacing: 5) {
            ForEach([1, 5, 10, 25], id: \.self) { minutes in
                Button {
                    timers.countdownDuration = TimeInterval(minutes * 60)
                    timers.reset()
                } label: {
                    Text("\(minutes)m")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(0.08)))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .buttonStyle(.plain)
            }
            Button { timers.adjustCountdown(by: 60) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.white.opacity(0.08)))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .buttonStyle(.plain)
            .help("Add a minute")
        }
    }

    private var pomodoroStatus: some View {
        HStack(spacing: 6) {
            Text(timers.pomodoroPhase.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text("· \(timers.completedFocusSessions) done today")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}
