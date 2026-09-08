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

    /// Everything enabled, minus what is already visible on the Dashboard —
    /// there is no point offering a second route to something on screen.
    private var tools: [WidgetKind] {
        let onDashboard = Set(settings.dashboardWidgets.map(\.rawValue))
        return settings.orderedWidgets.filter {
            $0 != .shelf && !onDashboard.contains($0.rawValue)
        }
    }

    var body: some View {
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
    @ObservedObject private var mirror = MirrorManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(tool.label)
                .font(Theme.sectionTitle)
                .foregroundStyle(Theme.tertiaryText)
                .textCase(.uppercase)
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
        case .mirror: MirrorWidgetView()
        case .timers: TimerWidgetView()
        case .notes: NotesWidgetView()
        case .todo: TodoWidgetView()
        case .shortcuts: ShortcutsWidgetView()
        case .sessions: SessionsWidgetView()
        case .stats: StatsWidgetView()
        }
    }
}
