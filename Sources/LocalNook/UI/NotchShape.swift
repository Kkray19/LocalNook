//
//  NotchShape.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import SwiftUI

/// The notch silhouette: two concave "flares" at the top that blend into the
/// screen edge, and two convex rounded corners at the bottom.
///
/// The flares are drawn *inside* `rect`, so the opaque body spans
/// `rect.width - 2 * topRadius`. Callers size the container accordingly via
/// ``NotchShape/totalWidth(forBody:topRadius:)``.
nonisolated struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    /// Lets SwiftUI interpolate the corner radii during the open/close spring
    /// instead of snapping them at the end of the animation.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    static func totalWidth(forBody body: CGFloat, topRadius: CGFloat) -> CGFloat {
        body + topRadius * 2
    }

    func path(in rect: CGRect) -> Path {
        let tr = max(0, min(topRadius, rect.width / 2))
        let br = max(0, min(bottomRadius, rect.height, (rect.width - tr * 2) / 2))

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Concave top-left flare.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
            control: CGPoint(x: rect.minX + tr, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))

        // Convex bottom-left corner.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tr + br, y: rect.maxY),
            control: CGPoint(x: rect.minX + tr, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))

        // Convex bottom-right corner.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
            control: CGPoint(x: rect.maxX - tr, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))

        // Concave top-right flare.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - tr, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}

/// Animation curves used across the app, in one place so motion feels uniform.
enum NotchMotion {
    /// Honours both the app setting and the system Reduce Motion preference.
    static var isAnimated: Bool {
        let settings = Settings.shared
        guard settings.animationsEnabled else { return false }
        if settings.respectReducedMotion,
           NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return false
        }
        return true
    }

    /// The main open/close spring.
    ///
    /// Softer and longer-settling than a merely fast animation: the notch
    /// should read as a body relaxing into shape, not a box being resized.
    /// `dampingFraction` below 1 gives a single visible overshoot, which is
    /// what separates "liquid" from "linear" — a heavily damped spring at a
    /// short response is perceptually indistinguishable from an ease curve.
    ///
    /// **The overshoot has a hard ceiling.** The panel window does not resize
    /// during the animation; the content animates inside a window that is
    /// `NotchGeometry.shadowPadding` (24pt) taller than the open state and
    /// about 32pt wider on each side. Anything that overshoots past that is
    /// clipped by the window edge and looks broken rather than springy. At
    /// damping 0.68 the overshoot is roughly 5–6% of travel — about 8pt
    /// vertically and 14pt per side horizontally — which stays inside it.
    /// Lowering this further means enlarging the window first.
    static var expand: Animation {
        isAnimated
            ? .spring(response: 0.46, dampingFraction: 0.68, blendDuration: 0.15)
            : .linear(duration: 0.01)
    }

    /// Small, frequent changes — a live activity appearing, the closed width
    /// tracking a geometry change. Springy for consistency, but tighter: these
    /// fire often and an overshoot on every one would read as instability.
    static var quick: Animation {
        isAnimated
            ? .spring(response: 0.3, dampingFraction: 0.8)
            : .linear(duration: 0.01)
    }

    /// Content inside the panel — page changes, sections appearing.
    ///
    /// Also a spring rather than the ease curve it used to be. With the shell
    /// springing and the contents easing, the two arrived on different
    /// schedules and the panel read as a box with a separate animation playing
    /// inside it. Slightly quicker than `expand` so the contents settle just
    /// after the shape rather than fighting it.
    static var content: Animation {
        isAnimated
            ? .spring(response: 0.34, dampingFraction: 0.82)
            : .linear(duration: 0.01)
    }
}
