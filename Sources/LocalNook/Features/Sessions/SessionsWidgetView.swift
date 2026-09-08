//
//  SessionsWidgetView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import SwiftUI

struct SessionsWidgetView: View {
    @ObservedObject private var monitor = SessionMonitor.shared
    @EnvironmentObject var settings: Settings

    var body: some View {
        VStack(spacing: 5) {
            header
            if monitor.sessions.isEmpty {
                WidgetMessage(
                    symbol: "brain.head.profile",
                    title: "No recent agent sessions",
                    detail: "LocalNook watches Claude Code and Codex transcript folders for activity. It reads timestamps only, never the conversations."
                )
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(monitor.sessions) { session in
                            SessionRow(session: session)
                        }
                    }
                }
            }
        }
        .onAppear { monitor.start() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            let active = monitor.activeSessions.count
            Circle()
                .fill(active > 0 ? Color.green : Color.white.opacity(0.25))
                .frame(width: 6, height: 6)
            Text(active > 0 ? "\(active) recently active" : "All quiet")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
            Text("metadata only")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.3))
            Button { monitor.rescan() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 9))
            }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.45))
        }
    }
}

private struct SessionRow: View {
    let session: AgentSession

    private var statusColour: Color {
        if session.isActive { return .green }
        if session.isIdle { return .orange }
        return .white.opacity(0.25)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.agent.symbol)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 0) {
                Text(session.projectName)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.9))
                Text(session.agent.label)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
            }

            Spacer(minLength: 6)

            Text(session.relativeActivity)
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.45))

            Circle().fill(statusColour).frame(width: 5, height: 5)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.045)))
        .help(session.isActive ? "Recently modified" : session.isIdle ? "Quiet — status inferred from timestamp" : "No recent writes")
    }
}
