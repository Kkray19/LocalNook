//
//  DashboardView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Several complementary widgets side by side, rather than one widget at a time
//  behind a strip of icons.
//
//  Sections are laid out by weight, but a section that cannot reach its minimum
//  readable width is dropped entirely rather than squeezed. Making everything
//  slightly too small to read is worse than showing one fewer thing.
//

import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: NotchViewModel
    @EnvironmentObject var settings: Settings

    var body: some View {
        GeometryReader { geometry in
            let chosen = settings.dashboardWidgets
            let visible = Self.fit(chosen, into: geometry.size.width)

            if visible.isEmpty {
                CompactMessage(
                    symbol: "square.grid.2x2",
                    title: "No dashboard widgets",
                    detail: "Choose what appears here in Settings ▸ Widgets.",
                    actionTitle: "Open Settings"
                ) {
                    NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element) { index, kind in
                        DashboardSection(kind: kind, model: model)
                            .frame(width: Self.width(for: kind, in: visible, total: geometry.size.width))

                        if index < visible.count - 1 {
                            SectionDivider()
                                .padding(.horizontal, Theme.sectionGap / 2)
                        }
                    }
                }
            }
        }
    }

    /// Drops sections from the end until the rest clear their minimum widths.
    static func fit(_ kinds: [WidgetKind], into width: CGFloat) -> [WidgetKind] {
        var candidates = kinds
        while !candidates.isEmpty {
            let dividers = CGFloat(max(0, candidates.count - 1)) * Theme.sectionGap
            let needed = candidates.reduce(0) { $0 + $1.dashboardMinimumWidth } + dividers
            if needed <= width { return candidates }
            candidates.removeLast()
        }
        return []
    }

    /// Weighted share of the remaining width.
    static func width(for kind: WidgetKind, in visible: [WidgetKind], total: CGFloat) -> CGFloat {
        let dividers = CGFloat(max(0, visible.count - 1)) * Theme.sectionGap
        let available = max(0, total - dividers)
        let weightSum = visible.reduce(0) { $0 + $1.dashboardWeight }
        guard weightSum > 0 else { return available }
        return available * (kind.dashboardWeight / weightSum)
    }
}

/// Routes a dashboard slot to its compact presentation.
private struct DashboardSection: View {
    let kind: WidgetKind
    @ObservedObject var model: NotchViewModel

    var body: some View {
        switch kind {
        case .media: CompactMediaView()
        case .calendar: CompactCalendarView()
        case .mirror: MirrorActionCard(model: model)
        case .timers: CompactTimerView(model: model)
        case .stats: CompactStatsView()
        case .sessions: CompactSessionsView(model: model)
        default: EmptyView()
        }
    }
}
