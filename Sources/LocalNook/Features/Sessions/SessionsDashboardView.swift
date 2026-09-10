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
    var showsLimits: Bool

    static let summaryWidth: CGFloat = 128
    static let limitsWidth: CGFloat = 190
    /// The list's own floor. Below this the rails are worth less than the rows.
    static let minimumListWidth: CGFloat = 240
    static let railGap: CGFloat = 12

    static func plan(width: CGFloat) -> SessionsDashboardLayout {
        let summaryCost = summaryWidth + railGap * 2 + 1
        let activityCost = limitsWidth + railGap * 2 + 1
        // The limits rail is the first thing to go. It is the most useful
        // thing here and also the most self-contained: losing it costs a
        // reading, where losing the list costs the page its purpose.
        if width >= minimumListWidth + summaryCost + activityCost {
            return SessionsDashboardLayout(showsSummary: true, showsLimits: true)
        }
        if width >= minimumListWidth + summaryCost {
            return SessionsDashboardLayout(showsSummary: true, showsLimits: false)
        }
        return SessionsDashboardLayout(showsSummary: false, showsLimits: false)
    }
}

struct SessionsDashboardView: View {
    @ObservedObject private var monitor = SessionMonitor.shared
    @EnvironmentObject var settings: Settings

    /// What the middle column is listing.
    enum Mode: String, CaseIterable, Identifiable {
        case sessions
        case projects
        case models

        var id: String { rawValue }
        var label: String {
            switch self {
            case .sessions: "Sessions"
            case .projects: "Projects"
            case .models: "Tokens"
            }
        }
    }

    /// Which tab a freshly-built page starts on.
    ///
    /// Only `--render-preview` writes this, and only so a scene can capture a
    /// tab the renderer has no way to click. Never written in normal
    /// operation, where the tabs own the selection from the first frame.
    nonisolated(unsafe) static var previewMode: Mode = .sessions

    @LNState private var mode: Mode = SessionsDashboardView.previewMode

    /// Folders across the sessions being shown — the same thirty the list is
    /// capped at, not the whole week. The week's own total is in the summary,
    /// where it is labelled as such.
    private var breakdown: ProjectBreakdown {
        ProjectBreakdown.build(from: monitor.sessions)
    }

    private var usage: UsageSummary {
        UsageSummary.build(from: monitor.sessions)
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

                if layout.showsLimits {
                    SectionDivider()
                        .padding(.horizontal, SessionsDashboardLayout.railGap)
                    limitsRail
                        .frame(width: SessionsDashboardLayout.limitsWidth)
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
                        case .models:
                            let models = usage.models
                            if models.isEmpty {
                                Text("No model reported yet.")
                                    .font(Theme.caption)
                                    .foregroundStyle(Theme.tertiaryText)
                                    .padding(.top, 6)
                            }
                            ForEach(models) { entry in
                                ModelUsageRow(entry: entry)
                            }
                        }
                    }
                    .padding(.trailing, 2)
                }
            }
        }
    }

    // MARK: Limits

    /// The account's rate-limit windows, as the agents last wrote them down.
    ///
    /// Deliberately not uniform across makers, because the data is not: see
    /// SessionUsage. A maker that publishes nothing gets a sentence saying so,
    /// which is the one thing an empty bar could never say.
    private var limitsRail: some View {
        let summary = usage
        return VStack(alignment: .leading, spacing: 5) {
            Text("Limits")
                .font(Theme.sectionTitle)
                .textCase(.uppercase)
                .foregroundStyle(Theme.tertiaryText)

            if summary.limits.isEmpty && summary.providersWithoutLimits.isEmpty {
                Text("Nothing recorded yet.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.quaternaryText)
            }

            ForEach(summary.limits) { window in
                LimitBar(window: window)
            }

            ForEach(summary.providersWithoutLimits, id: \.self) { provider in
                HStack(spacing: 4) {
                    Image(systemName: provider.symbol)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(LiveActivityCenter.tint(for: provider))
                    Text("\(provider.label) publishes no limits here")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.quaternaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .help("LocalNook makes no network requests, so it can only show "
                      + "figures an agent writes to this Mac. \(provider.label) "
                      + "records no rate-limit state in its session files.")
            }

            Spacer(minLength: 0)
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
                .fixedSize()
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
///
/// Pressing it brings the maker's app forward. See AgentApplication for why
/// that is the maker's app rather than the exact window, and why a row whose
/// app is not installed is not pressable.
private struct SessionDashboardRow: View {
    let session: AgentSession

    @LNState private var isHovering = false

    /// Resolved once per row rather than per frame: this is a LaunchServices
    /// lookup, and `body` runs whenever anything on the page changes.
    private var application: String? {
        AgentApplication.displayName(for: session.agent.provider)
    }

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
        if let application {
            Button {
                AgentApplication.open(session.agent.provider)
            } label: {
                row
            }
            .buttonStyle(.plain)
            .onHover { hovering in withAnimation(NotchMotion.quick) { isHovering = hovering } }
            .help("Open \(application)")
            .accessibilityLabel("Open \(application)")
        } else {
            row
                .help("\(session.agent.provider.label)'s app is not installed on this Mac.")
        }
    }

    private var row: some View {
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

            // Only where pressing does something, and only while pointed at.
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 10)
                .opacity(application != nil && isHovering ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
            .fill(isHovering && application != nil ? Theme.surfaceHover : Theme.surface))
        .contentShape(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous))
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

/// One rate-limit window: how much of it is gone, and when it comes back.
///
/// The percentage is a snapshot, not a live reading, so this shows how old it
/// is whenever that is old enough to matter — and once the window has rolled
/// over it says so rather than continuing to draw a bar for a period that has
/// ended.
private struct LimitBar: View {
    let window: RateLimitWindow

    /// Repainted on a timer because the only thing moving here is the clock.
    private let ticker = Timer.publish(every: 20, on: .main, in: .common).autoconnect()
    @LNState private var now = Date()

    private var expired: Bool { window.hasExpired(now: now) }

    private var fill: Color {
        if expired { return Theme.quaternaryText }
        return switch window.usedPercent {
        case ..<70: LiveActivityCenter.tint(for: window.provider)
        case ..<90: Theme.warning
        default: Theme.weekend
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: window.provider.symbol)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(LiveActivityCenter.tint(for: window.provider))
                Text(window.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 2)
                Text(expired ? "reset" : "\(Int(window.usedPercent.rounded()))%")
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(expired ? Theme.quaternaryText : Theme.primaryText)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.primaryText.opacity(0.12))
                    Capsule().fill(fill)
                        .frame(width: expired ? 0
                               : max(2, geometry.size.width * window.usedPercent / 100))
                }
            }
            .frame(height: 4)

            HStack(spacing: 4) {
                if let resets = window.resetText(now: now) {
                    Text("resets in \(resets)")
                } else {
                    Text("window has reset")
                }
                Spacer(minLength: 2)
                // Shown only when the reading is old enough that saying
                // nothing would imply it is current.
                if let age = window.ageText(now: now) {
                    Text(age)
                }
            }
            .font(.system(size: 8.5))
            .foregroundStyle(Theme.quaternaryText)
            .lineLimit(1)
        }
        .onReceive(ticker) { now = $0 }
        .help(window.provider.label + " " + window.label + " window — "
              + (window.ageText(now: now).map { "as read from a session transcript \($0)." }
                 ?? "read from a session transcript just now."))
    }
}

/// Tokens attributed to one model.
private struct ModelUsageRow: View {
    let entry: ModelUsage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.provider.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LiveActivityCenter.tint(for: entry.provider))
                .frame(width: 13)

            VStack(alignment: .leading, spacing: 0) {
                Text(entry.model ?? "Model not recorded")
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(entry.model == nil ? Theme.secondaryText
                                     : Theme.primaryText)
                    .help(entry.model == nil
                          ? "These tokens are real; the record naming the model "
                            + "was outside the part of the transcript LocalNook reads."
                          : entry.model ?? "")
                // "recent" is doing real work here. The Week count in the
                // summary rail spans every transcript the scan found; token
                // counts only exist for the handful LocalNook actually opens,
                // so without this word the two numbers look like parts of one
                // picture. See SessionMonitor.scan.
                Text("\(entry.sessions) recent session\(entry.sessions == 1 ? "" : "s")")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiaryText)
                    .help("Only sessions LocalNook has read carry token counts — "
                          + "the most recent few. This is not an account total.")
            }

            Spacer(minLength: 6)

            if entry.tokensUnreported {
                // Not zero. Claude Code writes per-message usage and no running
                // total, and summing every message would mean reading whole
                // transcripts — see SessionUsage.
                Text("not reported")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.quaternaryText)
                    .help("\(entry.provider.label) does not record a session token "
                          + "total in its transcripts, and LocalNook makes no "
                          + "network requests.")
            } else {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(TokenUsage.short(entry.tokens.total))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.primaryText)
                    Text("\(TokenUsage.short(entry.tokens.output)) out")
                        .font(.system(size: 8.5))
                        .monospacedDigit()
                        .foregroundStyle(Theme.quaternaryText)
                }
                .help("\(entry.tokens.input) in, \(entry.tokens.cachedInput) cached, "
                      + "\(entry.tokens.output) out")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
            .fill(Theme.surface))
    }
}
