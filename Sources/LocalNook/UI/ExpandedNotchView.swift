//
//  ExpandedNotchView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import SwiftUI

/// Contents of the notch while it is expanded: a widget rail on the left and
/// the selected widget's detail on the right.
struct ExpandedNotchView: View {
    @ObservedObject var model: NotchViewModel
    @EnvironmentObject var settings: Settings

    private var widgets: [WidgetKind] { settings.orderedWidgets }

    var body: some View {
        HStack(spacing: 12) {
            rail
            Divider().overlay(Color.white.opacity(0.12))
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(.white)
    }

    private var rail: some View {
        VStack(spacing: 6) {
            ForEach(widgets) { widget in
                Button {
                    withAnimation(NotchMotion.content) { model.selectedWidget = widget }
                } label: {
                    Image(systemName: widget.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 22)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(model.selectedWidget == widget
                                      ? Color.white.opacity(0.16)
                                      : Color.clear)
                        }
                        .foregroundStyle(model.selectedWidget == widget ? .white : .white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help(widget.label)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 30)
    }

    @ViewBuilder
    private var detail: some View {
        switch effectiveWidget {
        case .media: Text("Media").placeholderWidget()
        case .shelf: Text("Shelf").placeholderWidget()
        case .calendar: Text("Calendar").placeholderWidget()
        case .mirror: Text("Mirror").placeholderWidget()
        case .timers: Text("Timers").placeholderWidget()
        case .notes: Text("Notes").placeholderWidget()
        case .todo: Text("To-Do").placeholderWidget()
        case .shortcuts: Text("Shortcuts").placeholderWidget()
        case .sessions: Text("Sessions").placeholderWidget()
        case .stats: Text("Stats").placeholderWidget()
        }
    }

    /// Falls back to the first enabled widget if the selection was turned off.
    private var effectiveWidget: WidgetKind {
        widgets.contains(model.selectedWidget) ? model.selectedWidget : (widgets.first ?? .media)
    }
}

extension View {
    /// Temporary scaffolding while individual widgets are being built out.
    func placeholderWidget() -> some View {
        font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
