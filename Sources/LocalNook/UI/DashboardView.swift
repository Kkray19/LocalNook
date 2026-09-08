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
//  Sections are laid out by weight. A section that cannot reach its minimum
//  readable width is not squeezed — making everything slightly too small to read
//  is worse than showing one fewer thing — but it is not silently discarded
//  either. Whatever does not fit moves into a visible overflow control that says
//  how many are hidden and opens them, so a widget the user enabled can never
//  become unreachable just because the panel is narrow.
//

import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: NotchViewModel
    @EnvironmentObject var settings: Settings

    var body: some View {
        GeometryReader { geometry in
            let chosen = settings.dashboardWidgets
            let plan = Self.plan(chosen, into: geometry.size.width)
            let visible = plan.visible

            if visible.isEmpty, plan.overflow.isEmpty {
                CompactMessage(
                    symbol: "square.grid.2x2",
                    title: "No dashboard widgets",
                    detail: "Choose what appears here in Settings ▸ Widgets.",
                    actionTitle: "Open Settings"
                ) {
                    NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
                }
            } else {
                let sectionSpace = geometry.size.width
                    - (plan.overflow.isEmpty ? 0 : Self.overflowWidth + Theme.sectionGap)

                HStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element) { index, kind in
                        DashboardSection(kind: kind, model: model)
                            .frame(width: Self.width(for: kind, in: visible, total: sectionSpace))

                        if index < visible.count - 1 {
                            SectionDivider()
                                .padding(.horizontal, Theme.sectionGap / 2)
                        }
                    }

                    if !plan.overflow.isEmpty {
                        SectionDivider()
                            .padding(.horizontal, Theme.sectionGap / 2)
                        OverflowControl(hidden: plan.overflow, model: model)
                            .frame(width: Self.overflowWidth)
                    }
                }
            }
        }
    }

    /// Width reserved for the overflow control when something does not fit.
    static let overflowWidth: CGFloat = 46

    /// What is shown, and what moved into the overflow control.
    struct Layout: Equatable {
        var visible: [WidgetKind]
        var overflow: [WidgetKind]
    }

    /// Fits as many sections as read properly, and hands the rest to overflow.
    ///
    /// Nothing is discarded: `visible + overflow` always equals the input, so a
    /// widget the user enabled stays reachable at any panel width.
    static func plan(_ kinds: [WidgetKind], into width: CGFloat) -> Layout {
        guard !kinds.isEmpty else { return Layout(visible: [], overflow: []) }

        var candidates = kinds
        while !candidates.isEmpty {
            let hidden = kinds.count - candidates.count
            // Making room for the overflow control is itself a cost, so it has
            // to be part of the fit rather than an afterthought.
            let reserve = hidden > 0 ? overflowWidth + Theme.sectionGap : 0
            let dividers = CGFloat(max(0, candidates.count - 1)) * Theme.sectionGap
            let needed = candidates.reduce(0) { $0 + $1.dashboardMinimumWidth } + dividers + reserve
            if needed <= width {
                return Layout(visible: candidates, overflow: Array(kinds.dropFirst(candidates.count)))
            }
            candidates.removeLast()
        }
        // Too narrow even for one section: everything is still reachable.
        return Layout(visible: [], overflow: kinds)
    }

    /// Convenience for callers that only care what is on screen.
    static func fit(_ kinds: [WidgetKind], into width: CGFloat) -> [WidgetKind] {
        plan(kinds, into: width).visible
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

/// Shown when the panel is too narrow for every chosen section.
///
/// Its job is to make the omission obvious and reversible: it names how many are
/// hidden and opens them, so nothing the user enabled disappears without trace.
private struct OverflowControl: View {
    let hidden: [WidgetKind]
    @ObservedObject var model: NotchViewModel
    @LNState private var isHovering = false

    var body: some View {
        Button {
            withAnimation(NotchMotion.content) {
                model.page = .tools
                model.focusedTool = hidden.count == 1 ? hidden[0] : nil
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(isHovering ? Theme.primaryText : Theme.secondaryText)
                Text("+\(hidden.count)")
                    .font(Theme.caption)
                    .monospacedDigit()
                    .foregroundStyle(isHovering ? Theme.secondaryText : Theme.tertiaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(isHovering ? Theme.surface : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(NotchMotion.quick) { isHovering = hovering } }
        .help(hidden.count == 1
              ? "\(hidden[0].label) does not fit — open it"
              : "\(hidden.count) sections do not fit — open them in Tools")
    }
}
