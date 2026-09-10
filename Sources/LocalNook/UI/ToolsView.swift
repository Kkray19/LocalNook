//
//  ToolsView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Tools keeps everything that needs more room than a dashboard column: timers,
//  notes, tasks, Shortcuts, sessions and stats. Picking one opens its focused
//  view, which uses the same spacing and type as the rest of the panel.
//

import SwiftUI

struct ToolsView: View {
    @ObservedObject var model: NotchViewModel
    @EnvironmentObject var settings: Settings

    /// Everything enabled, minus what is genuinely **visible** on the Dashboard.
    ///
    /// The distinction matters and getting it wrong made widgets unreachable.
    /// This used to exclude everything *assigned* to the Dashboard, on the
    /// reasoning that there is no point offering a second route to something
    /// already on screen. But a widget assigned to the Dashboard is not
    /// necessarily on it: when more are assigned than fit, the rest move into
    /// the overflow control — whose action is to bring the user *here*. So the
    /// three widgets the overflow badge counted were excluded from the one page
    /// it sent people to, and were reachable from nowhere at all.
    ///
    /// Computed at this page's own width. Tools and Dashboard render in the
    /// same container, so the same plan yields the same split; and if the two
    /// ever disagree, the error falls the safe way — a narrower Tools shows
    /// *more*, which is a redundant route rather than a missing one.
    private func tools(inWidth width: CGFloat) -> [WidgetKind] {
        let visibleOnDashboard = Set(
            DashboardView.plan(settings.dashboardWidgets, into: width).visible.map(\.rawValue)
        )
        return settings.orderedWidgets.filter {
            $0 != .shelf && !visibleOnDashboard.contains($0.rawValue)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let tools = tools(inWidth: geometry.size.width)
            if tools.isEmpty {
                CompactMessage(
                    symbol: "wrench.and.screwdriver",
                    title: "Every widget is on the Dashboard",
                    detail: "Enable more in Settings ▸ Widgets."
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(tools) { tool in
                            ToolTile(tool: tool) {
                                withAnimation(NotchMotion.content) { model.focusedTool = tool }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

private struct ToolTile: View {
    let tool: WidgetKind
    let action: () -> Void
    @LNState private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(isHovering ? Theme.primaryText : Theme.secondaryText)
                Text(tool.label)
                    .font(Theme.caption)
                    .foregroundStyle(isHovering ? Theme.secondaryText : Theme.tertiaryText)
                    .lineLimit(1)
            }
            .frame(width: 84, height: 74)
            .background {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(isHovering ? Theme.surfaceHover : Theme.surface)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(NotchMotion.quick) { isHovering = hovering } }
    }
}

/// A single tool at full size.
struct FocusedToolView: View {
    let tool: WidgetKind

    /// Sections that title themselves.
    ///
    /// The panel is about 120pt tall inside the shoulders, and a title on its
    /// own line costs a fifth of that. A section dense enough to need the
    /// height puts its name on a row it was drawing anyway.
    private var drawsOwnTitle: Bool { tool == .sessions }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !drawsOwnTitle {
                Text(tool.label)
                    .font(Theme.sectionTitle)
                    .foregroundStyle(Theme.tertiaryText)
                    .textCase(.uppercase)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tool {
        case .media: MediaWidgetView()
        case .shelf: EmptyView()
        case .calendar: CalendarWidgetView()
        case .timers: TimerWidgetView()
        case .notes: NotesWidgetView()
        case .todo: TodoWidgetView()
        case .shortcuts: ShortcutsWidgetView()
        case .sessions: SessionsDashboardView()
        case .stats: StatsWidgetView()
        }
    }
}
