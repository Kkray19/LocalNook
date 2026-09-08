//
//  ExpandedNotchView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import SwiftUI

/// Contents of the notch while it is expanded.
///
/// Layout is driven by two hard constraints:
///
/// 1. The top `closedHeight` points sit behind the physical camera housing, so
///    nothing readable may be placed there. That strip carries only the two
///    small shoulders either side of the notch.
/// 2. The panel is wide and short (640×190 by default), so the widget picker is
///    a horizontal strip rather than a vertical rail — a rail tall enough for
///    ten widgets would not fit.
struct ExpandedNotchView: View {
    @ObservedObject var model: NotchViewModel
    @EnvironmentObject var settings: Settings

    private var widgets: [WidgetKind] { settings.orderedWidgets }

    /// Height of the strip hidden behind the physical notch.
    private var shoulderHeight: CGFloat { max(model.closedSize.height, 24) }

    var body: some View {
        VStack(spacing: 0) {
            shoulders
                .frame(height: shoulderHeight)
            tabStrip
                .padding(.top, 2)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 8)
        }
        .foregroundStyle(.white)
    }

    /// The usable area either side of the camera housing: a title on the left,
    /// a close affordance on the right.
    private var shoulders: some View {
        HStack(spacing: 0) {
            Text(effectiveWidget.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Dead zone behind the physical notch.
            Spacer(minLength: 0)
                .frame(width: model.closedSize.width)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button {
                    NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.55))
                .help("LocalNook Settings")

                Button { model.close() } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.55))
                .help("Collapse")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 3) {
            ForEach(widgets) { widget in
                let selected = effectiveWidget == widget
                Button {
                    withAnimation(NotchMotion.content) { model.selectedWidget = widget }
                } label: {
                    Image(systemName: widget.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 30, height: 20)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selected ? Color.white.opacity(0.18) : .clear)
                        }
                        .foregroundStyle(selected ? .white : .white.opacity(0.45))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(widget.label)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var detail: some View {
        if widgets.isEmpty {
            WidgetMessage(symbol: "square.grid.2x2", title: "No widgets enabled",
                          detail: "Choose widgets in LocalNook Settings.")
        } else { switch effectiveWidget {
        case .media: MediaWidgetView()
        case .shelf: ShelfWidgetView(model: model)
        case .calendar: CalendarWidgetView()
        case .mirror: MirrorWidgetView()
        case .timers: TimerWidgetView()
        case .notes: NotesWidgetView()
        case .todo: TodoWidgetView()
        case .shortcuts: ShortcutsWidgetView()
        case .sessions: SessionsWidgetView()
        case .stats: StatsWidgetView()
        } }
    }

    /// Falls back to the first enabled widget if the selection was turned off.
    private var effectiveWidget: WidgetKind {
        widgets.contains(model.selectedWidget) ? model.selectedWidget : (widgets.first ?? .media)
    }
}

/// Shown for widgets that are not implemented yet, so the UI never renders an
/// empty box with no explanation.
struct PlaceholderWidget: View {
    let kind: WidgetKind

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: kind.symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text("\(kind.label) is not built yet")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
