//
//  SessionsDashboardView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  The AI Sessions page: the whole panel, rather than one dashboard column.
//
//  The compact column beside Media and Calendar can hold three truncated lines,
//  which is enough to notice something is running and not enough to learn
//  anything from. This is what opens when it is clicked: the same data with
//  room to be read, plus the counts the column has no space for.
//
//  Three regions, and they narrow in a fixed order rather than all shrinking
//  together — see `SessionsDashboardLayout`. The list is the part nobody can do
//  without, so it is the last thing standing.
//
//  Every number here comes from file metadata. Names, models and steps come
//  from SessionDetail, which reads four named fields and only with consent; the
//  footer says which of the two is in force, because "no names" and "no
//  sessions" look identical otherwise.
//

import SwiftUI

/// Which regions fit at a given panel width.
///
/// Pure, so the order things drop in can be asserted without measuring a
/// rendered view. The rule is that the list survives every width: a panel too
/// narrow for the counts should show fewer numbers, never fewer sessions.
nonisolated struct SessionsDashboardLayout: Equatable {
    var showsSummary: Bool
    var showsActivity: Bool

    static let summaryWidth: CGFloat = 128
    static let activityWidth: CGFloat = 176
    /// The list's own floor. Below this the rails are worth less than the rows.
    static let minimumListWidth: CGFloat = 240
    static let railGap: CGFloat = 12

    static func plan(width: CGFloat) -> SessionsDashboardLayout {
        let summaryCost = summaryWidth + railGap * 2 + 1
        let activityCost = activityWidth + railGap * 2 + 1
        // The activity chart is the first thing to go: it describes the week,
        // and the week is still legible from the "Week" count in the summary.
        if width >= minimumListWidth + summaryCost + activityCost {
            return SessionsDashboardLayout(showsSummary: true, showsActivity: true)
        }
        if width >= minimumListWidth + summaryCost {
            return SessionsDashboardLayout(showsSummary: true, showsActivity: false)
        }
        return SessionsDashboardLayout(showsSummary: false, showsActivity: false)
    }
}

struct SessionsDashboardView: View {
    @ObservedObject private var monitor = SessionMonitor.shared
    @EnvironmentObject var settings: Settings

    /// Whether the middle column lists sessions or the folders they are in.
    enum Mode: String, CaseIterable, Identifiable {
        case sessions
        case projects

        var id: String { rawValue }
        var label: String {
            switch self {
            case .sessions: "Sessions"
            case .projects: "Projects"
            }
        }
    }

    @LNState private var mode: Mode = .sessions

    /// Folders across the sessions being shown — the same thirty the list is
    /// capped at, not the whole week. The week's own total is in the summary,
    /// where it is labelled as such.
    private var breakdown: ProjectBreakdown {
        ProjectBreakdown.build(from: monitor.sessions)
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = SessionsDashboardLayout.plan(width: geometry.size.width)
            HStack(spacing: 0) {
                if layout.showsSummary {
                    summary
                        .frame(width: SessionsDashboardLayout.summaryWidth)
                    SectionDivider()
                        .padding(.horizontal, SessionsDashboardLayout.railGap)
                }

                list
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                if layout.showsActivity {
                    SectionDivider()
                        .padding(.horizontal, SessionsDashboardLayout.railGap)
                    activity
                        .frame(width: SessionsDashboardLayout.activityWidth)
                }
            }
        }
        .onAppear { monitor.start() }
    }

    // MARK: Summary

    private var summary: some View {
        let active = monitor.activeSessions.count
        let idle = monitor.sessions.filter(\.isIdle).count
        let stats = monitor.stats
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(active)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(active > 0 ? Theme.positive : Theme.secondaryText)
                Text("active")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
            // Says what "active" is measured by, so the number is not mistaken
            // for a claim that an agent is mid-thought.
            Text("written in the last 90s")
                .font(.system(size: 9))
                .foregroundStyle(Theme.quaternaryText)
                .lineLimit(1)

            Spacer(minLength: 6)

            StatLine(name: "Waiting", value: "\(idle)")
            StatLine(name: "Week", value: "\(stats.total)")
            StatLine(name: "Volume", value: SessionStats.volumeLabel(bytes: stats.totalBytes))

            Spacer(minLength: 4)
            depthFooter
        }
    }

    /// Whether names and steps are being read at all. Without this, a list of
    /// bare directory names looks like a bug rather than a setting.
    private var depthFooter: some View {
        let rich = settings.sessionLabelDepth == .richLabels
        return HStack(spacing: 4) {
            Image(systemName: rich ? "text.magnifyingglass" : "lock.shield")
                .font(.system(size: 8))
            Text(rich ? "names on" : "metadata only")
                .font(.system(size: 9))
                .lineLimit(1)
        }
        .foregroundStyle(Theme.quaternaryText)
        .help(rich
              ? "Chat names, models and steps are read from your local session files."
              : "Sessions are described by file name, size and timestamp only. "
                + "Turn on labels in Settings ▸ Widgets to see names and steps.")
    }

    // MARK: List

    private var list: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // The page's own name. It sits on this row rather than a line
                // of its own so the list keeps the height — see
                // FocusedToolView.drawsOwnTitle.
                Text(WidgetKind.sessions.label)
                    .font(Theme.sectionTitle)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize()
                    .padding(.trailing, 2)

                ForEach(Mode.allCases) { option in
                    ModeTab(
                        title: option.label,
                        isSelected: mode == option,
                        action: { withAnimation(NotchMotion.quick) { mode = option } }
                    )
                }
                Spacer(minLength: 4)
                if mode == .projects, breakdown.unattributed > 0 {
                    // Never silently dropped: a Codex session with no folder
                    // read is "unknown", not "none".
                    Text("+\(breakdown.unattributed) unknown")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.quaternaryText)
                        .help("Sessions whose working folder is not known. Codex "
                              + "records it inside the transcript, so it needs labels on.")
                }
                Button { monitor.rescan() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.tertiaryText)
                .help("Rescan now")
            }

            if monitor.sessions.isEmpty {
                CompactMessage(
                    symbol: "brain.head.profile",
                    title: "No recent agent sessions",
                    detail: "LocalNook watches the Claude Code and Codex transcript "
                        + "folders for activity."
                )
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 2) {
                        switch mode {
                        case .sessions:
                            ForEach(monitor.sessions) { session in
                                SessionDashboardRow(session: session)
                            }
                        case .projects:
                            ForEach(breakdown.projects) { project in
                                ProjectDashboardRow(project: project)
                            }
                        }
                    }
                    .padding(.trailing, 2)
                }
            }
        }
    }

    // MARK: Activity

    private var activity: some View {
        let stats = monitor.stats
        return VStack(alignment: .leading, spacing: 5) {
            Text("Last active")
                .font(Theme.sectionTitle)
                .textCase(.uppercase)
                .foregroundStyle(Theme.tertiaryText)
                .help("Sessions counted on the day they were last written to. A "
                      + "session that ran for three days counts once, on the last.")

            DayBars(stats: stats)
                .frame(maxHeight: .infinity)

            HStack(spacing: 6) {
                ForEach(SessionProvider.allCases, id: \.self) { provider in
                    let count = stats.perAgent
                        .filter { $0.key.provider == provider }
                        .values.reduce(0, +)
                    ProviderChip(provider: provider, count: count)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// A name and a number, on one line.
private struct StatLine: View {
    let name: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.vertical, 1.5)
    }
}

private struct ModeTab: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @LNState private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSelected ? Theme.primaryText : Theme.tertiaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background {
                    Capsule().fill(isSelected ? Theme.surfaceActive
                                   : (isHovering ? Theme.surface : .clear))
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(NotchMotion.quick) { isHovering = hovering } }
    }
}

/// One session, at the width the compact column never had.
private struct SessionDashboardRow: View {
    let session: AgentSession

    private var statusColour: Color {
        if session.isActive { return Theme.positive }
        if session.isIdle { return Theme.warning }
        return Theme.quaternaryText
    }

    private var subtitle: String {
        if let model = session.detail.modelLabel {
            return "\(model) · \(session.agent.label)"
        }
        return session.agent.label
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.agent.provider.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LiveActivityCenter.tint(for: session.agent.provider))
                .frame(width: 13)

            VStack(alignment: .leading, spacing: 0) {
                Text(session.displayName)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Theme.primaryText)

                if session.detail.showsProgress, let step = session.detail.step {
                    HStack(spacing: 5) {
                        SessionWorkingBar()
                        Text(step)
                            .font(.system(size: 9))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(Theme.secondaryText)
                    }
                } else {
                    Text(subtitle)
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }

            Spacer(minLength: 6)

            Text(SessionStats.volumeLabel(bytes: session.byteSize))
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(Theme.quaternaryText)
                .help("Transcript size on disk")

            Text(session.relativeActivity)
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 52, alignment: .trailing)

            Circle().fill(statusColour).frame(width: 5, height: 5)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
            .fill(Theme.surface))
        .help(session.isActive
              ? "Written in the last 90 seconds"
              : session.isIdle ? "Quiet — probably waiting on you" : "No recent writes")
    }
}

/// One working folder, and how much is going on in it.
private struct ProjectDashboardRow: View {
    let project: ProjectTally

    private var relative: String {
        let seconds = Int(Date().timeIntervalSince(project.lastActivity))
        return switch seconds {
        case ..<60: "just now"
        case ..<3600: "\(seconds / 60)m ago"
        case ..<86400: "\(seconds / 3600)h ago"
        default: "\(seconds / 86400)d ago"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 13)

            Text(project.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(Theme.primaryText)

            Spacer(minLength: 6)

            if project.active > 0 {
                HStack(spacing: 4) {
                    SessionWorkingBar()
                    Text("\(project.active)")
                        .font(.system(size: 9.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.positive)
                }
                .help("\(project.active) session\(project.active == 1 ? "" : "s") "
                      + "written in the last 90 seconds")
            }

            Text("\(project.sessions)")
                .font(.system(size: 9.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 20, alignment: .trailing)
                .help("Sessions in this folder")

            Text(relative)
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4.5)
        .background(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
            .fill(Theme.surface))
    }
}

/// Seven bars: how many sessions were last written on each of the last seven
/// days, today on the right.
private struct DayBars: View {
    let stats: SessionStats

    var body: some View {
        let counts = Array(stats.perDay.reversed())
        let initials = Array(SessionStats.dayInitials().reversed())
        let peak = stats.peakDay

        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(counts.enumerated()), id: \.offset) { index, count in
                let isToday = index == counts.count - 1
                VStack(spacing: 3) {
                    GeometryReader { geometry in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                // A day with nothing still draws its baseline,
                                // so an empty stretch reads as zero rather
                                // than as a chart that failed to load.
                                .fill(isToday ? Theme.accent
                                      : Theme.primaryText.opacity(count > 0 ? 0.32 : 0.15))
                                .frame(
                                    height: max(2, geometry.size.height
                                                * CGFloat(count) / CGFloat(peak))
                                )
                        }
                    }
                    Text(index < initials.count ? initials[index] : "")
                        .font(.system(size: 8, weight: isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? Theme.secondaryText : Theme.quaternaryText)
                }
                .frame(maxWidth: .infinity)
                .help("\(count) session\(count == 1 ? "" : "s") last written")
            }
        }
    }
}

/// How many sessions came from one maker.
private struct ProviderChip: View {
    let provider: SessionProvider
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: provider.symbol)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(LiveActivityCenter.tint(for: provider))
            Text(provider.label)
                .font(.system(size: 9))
                .foregroundStyle(Theme.tertiaryText)
            Text("\(count)")
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(count > 0 ? Theme.secondaryText : Theme.quaternaryText)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(Theme.surface))
    }
}
