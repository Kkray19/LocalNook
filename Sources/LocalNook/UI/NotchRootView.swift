//
//  NotchRootView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import SwiftUI

/// Root of the panel's SwiftUI hierarchy.
///
/// The hosting panel is a fixed size (always big enough for the open state);
/// this view animates the drawn notch inside it. Resizing the panel every frame
/// causes visible tearing — animating the content does not.
struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    @EnvironmentObject var settings: Settings

    private var isOpen: Bool { model.state == .open }

    private var topRadius: CGFloat {
        isOpen ? settings.openCornerRadius : settings.closedCornerRadius
    }

    private var bottomRadius: CGFloat {
        isOpen ? settings.openCornerRadius : settings.closedCornerRadius + 4
    }

    private var bodyWidth: CGFloat {
        isOpen ? NotchGeometry.openSize.width : model.closedSize.width
    }

    private var bodyHeight: CGFloat {
        isOpen ? NotchGeometry.openSize.height : model.effectiveClosedHeight
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Full-panel transparent catcher so SwiftUI hover/drop events fire
            // anywhere in the panel, not just over the drawn shape.
            Color.clear

            notchBody
                .frame(
                    width: NotchShape.totalWidth(forBody: bodyWidth, topRadius: topRadius),
                    height: bodyHeight
                )
                .animation(NotchMotion.expand, value: isOpen)
                .animation(NotchMotion.quick, value: model.closedSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(model.isSuppressed && !isOpen ? 0 : 1)
        .animation(NotchMotion.content, value: model.isSuppressed)
        .onHover { hovering in
            model.isHovering = hovering
            if hovering {
                model.scheduleOpen()
            } else if !model.isDragTargeting {
                model.scheduleClose()
            }
        }
    }

    private var notchBody: some View {
        NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
            .fill(Color.black)
            .overlay {
                // Subtle inner edge so the panel reads as an object against a
                // dark wallpaper rather than a hole.
                NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(isOpen ? 0.10 : 0), .white.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.6
                    )
            }
            .overlay(alignment: .top) { content }
            .shadow(color: .black.opacity(isOpen ? 0.45 : 0), radius: 18, y: 8)
            .contentShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
            .onTapGesture {
                guard settings.openTrigger.allowsClick else { return }
                model.toggle()
            }
    }

    @ViewBuilder
    private var content: some View {
        if isOpen {
            ExpandedNotchView(model: model)
                .padding(.horizontal, topRadius + settings.contentPadding)
                .padding(.bottom, settings.contentPadding)
                .frame(
                    width: NotchShape.totalWidth(forBody: bodyWidth, topRadius: topRadius),
                    height: bodyHeight
                )
                .transition(.opacity.combined(with: .offset(y: -6)))
        }
    }
}
