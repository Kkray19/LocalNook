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
///    shoulders either side of the notch — navigation on the left, actions on
///    the right — and the reserved centre stays exactly the notch's width.
/// 2. The panel is wide and short, so everyday information is composed as
///    columns on one Dashboard rather than one widget at a time behind a strip
///    of icons.
struct ExpandedNotchView: View {
    @ObservedObject var model: NotchViewModel
    @EnvironmentObject var settings: Settings

    /// Height of the strip hidden behind the physical camera housing.
    private var shoulderHeight: CGFloat { max(model.closedSize.height, 26) }

    var body: some View {
        VStack(spacing: 0) {
            shoulders
                .frame(height: shoulderHeight)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 4)
        }
        .foregroundStyle(Theme.primaryText)
    }

    // MARK: Shoulders

    /// The usable area either side of the camera housing.
    private var shoulders: some View {
        HStack(spacing: 0) {
            navigation
                .frame(maxWidth: .infinity, alignment: .leading)

            // Reserved for the camera housing — must stay centred and exactly
            // the notch's width.
            Color.clear
                .frame(width: model.closedSize.width)
                .allowsHitTesting(false)

            actions
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var navigation: some View {
        HStack(spacing: 3) {
            ForEach(NotchPage.allCases) { item in
                PageTab(
                    page: item,
                    isSelected: model.page == item,
                    action: {
                        withAnimation(NotchMotion.content) {
                            model.page = item
                            if item != .tools { model.focusedTool = nil }
                        }
                    }
                )
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if model.page == .tools, model.focusedTool != nil {
                Button {
                    withAnimation(NotchMotion.content) { model.focusedTool = nil }
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
                .help("Back to Tools")
            }

            Button {
                NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.tertiaryText)
            .help("LocalNook Settings")

            Button { model.close() } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.tertiaryText)
            .help("Collapse")
        }
    }

    // MARK: Pages

    @ViewBuilder
    private var page: some View {
        switch model.page {
        case .dashboard:
            DashboardView(model: model)
        case .tray:
            TrayView(model: model)
        case .tools:
            if let tool = model.focusedTool {
                FocusedToolView(tool: tool)
            } else {
                ToolsView(model: model)
            }
        }
    }
}

/// A navigation pill in the left shoulder.
private struct PageTab: View {
    let page: NotchPage
    let isSelected: Bool
    let action: () -> Void

    @LNState private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: page.symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(page.label)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Theme.primaryText : Theme.secondaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background {
                Capsule()
                    .fill(isSelected ? Theme.surfaceActive
                          : (isHovering ? Theme.surface : .clear))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(NotchMotion.quick) { isHovering = hovering }
        }
    }
}
