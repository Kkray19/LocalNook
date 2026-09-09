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

    /// Model and agent when there is no live step to show, e.g.
    /// "Opus 5 max · Claude Code".
    private var subtitle: String {
        if let model = session.detail.modelLabel {
            return "\(model) · \(session.agent.label)"
        }
        return session.agent.label
    }

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

            VStack(alignment: .leading, spacing: 1) {
                // The chat's own name, falling back to the directory when the
                // transcript has no title.
                Text(session.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.9))

                if session.detail.showsProgress, let step = session.detail.step {
                    // What it is doing right now, with the same pulsing bar the
                    // agents' own progress lines use.
                    HStack(spacing: 5) {
                        WorkingIndicator()
                        Text(step)
                            .font(.system(size: 9))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                } else {
                    Text(subtitle)
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.4))
                }
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

/// A small marching bar, matching the progress line the agents show while they
/// are working. Purely decorative: it says "still going", not how far along.
private struct WorkingIndicator: View {
    @LNState private var shift: CGFloat = -1

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.2))
            .frame(width: 16, height: 2.5)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(Color.green.opacity(0.9))
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
