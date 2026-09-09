//
//  ScreenGeometry.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Notch and screen geometry. The approach — deriving the physical notch width
//  from the gap between `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` — is
//  the same technique used by boring.notch (GPL-3.0).
//

import AppKit
import Foundation

/// A stable identifier for a display across sleep/wake and reconnection.
///
/// `NSScreen` objects are recreated on configuration changes, so we key
/// everything on the CoreGraphics display ID's UUID instead.
extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    var stableID: String? {
        guard let id = displayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func screen(withStableID id: String?) -> NSScreen? {
        guard let id else { return nil }
        return screens.first { $0.stableID == id }
    }

    /// True when the display has a physical camera housing cut into the panel.
    var hasPhysicalNotch: Bool {
        safeAreaInsets.top > 0 && auxiliaryTopLeftArea != nil && auxiliaryTopRightArea != nil
    }

    /// Width of the physical notch in points, or `nil` on displays without one.
    var physicalNotchWidth: CGFloat? {
        guard let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        let width = frame.width - left.width - right.width
        return width > 0 ? width : nil
    }

    /// Height of the menu bar, which is not always the same as the notch height.
    var menuBarHeight: CGFloat {
        max(0, frame.maxY - visibleFrame.maxY)
    }
}

/// Resolves the closed/open notch geometry for a given display, honouring the
/// user's height mode, width adjustment and virtual-notch settings.
enum NotchGeometry {
    /// A small outward bleed so the drawn shape overlaps the physical notch
    /// edges instead of leaving a hairline of wallpaper visible beside it.
    static let physicalWidthBleed: CGFloat = 4

    /// Extra room below the panel so the drop shadow is not clipped.
    static let shadowPadding: CGFloat = 24

    /// Everything about a display that affects notch geometry.
    ///
    /// Extracted from `NSScreen` so the geometry can be exercised for displays
    /// that are not physically attached — external monitors in particular, which
    /// otherwise could only be tested by plugging one in.
    struct DisplayMetrics: Equatable, Sendable {
        var frameWidth: CGFloat
        var safeAreaTop: CGFloat
        var menuBarHeight: CGFloat
        /// `nil` when the display has no camera housing.
        var physicalNotchWidth: CGFloat?

        var hasPhysicalNotch: Bool { physicalNotchWidth != nil && safeAreaTop > 0 }

        init(
            frameWidth: CGFloat,
            safeAreaTop: CGFloat,
            menuBarHeight: CGFloat,
            physicalNotchWidth: CGFloat?
        ) {
            self.frameWidth = frameWidth
            self.safeAreaTop = safeAreaTop
            self.menuBarHeight = menuBarHeight
            self.physicalNotchWidth = physicalNotchWidth
        }

        init(_ screen: NSScreen) {
            self.init(
                frameWidth: screen.frame.width,
                safeAreaTop: screen.safeAreaInsets.top,
                menuBarHeight: screen.menuBarHeight,
                physicalNotchWidth: screen.hasPhysicalNotch ? screen.physicalNotchWidth : nil
            )
        }

        /// A typical external monitor: no camera housing, standard menu bar.
        static func external(width: CGFloat, menuBarHeight: CGFloat = 24) -> DisplayMetrics {
            DisplayMetrics(
                frameWidth: width, safeAreaTop: 0,
                menuBarHeight: menuBarHeight, physicalNotchWidth: nil
            )
        }
    }

    static func closedSize(for screen: NSScreen?) -> CGSize {
        guard let screen else {
            let settings = Settings.shared
            return CGSize(width: settings.virtualNotchWidth, height: settings.virtualNotchHeight)
        }
        return closedSize(for: DisplayMetrics(screen))
    }

    /// Pure geometry: the collapsed notch size for a display with `metrics`.
    static func closedSize(for metrics: DisplayMetrics) -> CGSize {
        let settings = Settings.shared

        if metrics.hasPhysicalNotch {
            let width = (metrics.physicalNotchWidth ?? 185) + physicalWidthBleed
                + settings.notchWidthAdjustment
            let height: CGFloat = switch settings.notchHeightMode {
            case .matchRealNotch: metrics.safeAreaTop
            case .matchMenuBar: metrics.menuBarHeight
            case .custom: settings.customNotchHeight
            }
            return CGSize(width: max(60, width), height: max(1, height))
        }

        // Display without a notch — an external monitor, or a Mac with no
        // camera housing. Draw a virtual one if the user wants it.
        guard settings.virtualNotchEnabled else { return .zero }
        let height: CGFloat = switch settings.notchHeightMode {
        case .matchMenuBar: metrics.menuBarHeight
        // `matchRealNotch` is meaningless without a real notch; fall back to
        // the configured virtual height rather than collapsing to zero.
        default: settings.virtualNotchHeight
        }
        return CGSize(
            width: max(60, settings.virtualNotchWidth + settings.notchWidthAdjustment),
            height: max(1, height)
        )
    }

    static var openSize: CGSize {
        let settings = Settings.shared
        return CGSize(width: settings.openWidth, height: settings.openHeight)
    }

    /// Horizontal room either side of the open panel, so live activities can
    /// render beside the *closed* notch without being clipped by the window.
    static let sideGutter: CGFloat = 130

    /// The panel never resizes — it is always big enough for the open state plus
    /// its flares, shadow and side gutters, and the SwiftUI content animates
    /// inside it. Resizing an `NSPanel` every frame produces visible tearing;
    /// animating the content does not.
    ///
    /// The width must cover the widest thing ever drawn, because `NSHostingView`
    /// will otherwise grow the window to fit and knock it off centre.
    static func windowSize(for screen: NSScreen?) -> CGSize {
        let settings = Settings.shared
        let open = openSize
        let closed = closedSize(for: screen)
        let widest: CGFloat = max(open.width + CGFloat(settings.openCornerRadius) * 2,
                                  closed.width + sideGutter * 2 + settings.closedCornerRadius * 2)
            + shadowPadding * 2
        let available: CGFloat = screen.map(\.frame.width) ?? widest
        return CGSize(
            width: min(widest, available),
            height: open.height + shadowPadding
        )
    }

    static func collapsedWindowSize(
        closed: CGSize, hasActivity: Bool, expandedActivity: Bool = false
    ) -> CGSize {
        let body = hasActivity
            ? ClosedActivityView.totalBodyWidth(notchWidth: closed.width, expanded: expandedActivity)
            : closed.width
        return CGSize(width: body + 2 * Settings.shared.closedCornerRadius,
                      height: max(4, closed.height) + 3)
    }

    /// Frame origin that centres the panel on the top edge of `screen`.
    static func windowOrigin(on screen: NSScreen, windowSize: CGSize) -> NSPoint {
        windowOrigin(inFrame: screen.frame, windowSize: windowSize)
    }

    /// Pure form, so placement on a display with a non-zero frame origin — every
    /// external monitor — can be tested without attaching one.
    static func windowOrigin(inFrame frame: CGRect, windowSize: CGSize) -> NSPoint {
        NSPoint(
            x: frame.origin.x + (frame.width - windowSize.width) / 2,
            y: frame.origin.y + frame.height - windowSize.height
        )
    }

    /// Whether LocalNook should show anything at all on this display.
    static func shouldDisplay(on screen: NSScreen) -> Bool {
        screen.hasPhysicalNotch || Settings.shared.virtualNotchEnabled
    }
}
