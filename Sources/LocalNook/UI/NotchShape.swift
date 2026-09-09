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

    /// The main open/close motion.
    ///
    /// Expressed as duration and bounce, which is the parameterisation Apple
    /// moved to in WWDC23 and the one that matches how this actually reads:
    /// bounce is what the eye calls "springy", duration is the settle. The two
    /// map onto the old form as roughly `bounce = 1 - dampingFraction`.
    ///
    /// This has been tuned twice from opposite directions. It began at damping
    /// 0.78 — bounce 0.22 at a short response — which read as linear, because a
    /// heavily damped spring over a short settle is perceptually an ease curve.
    /// Overcorrecting to damping 0.68 (bounce 0.32) read as springy but not
    /// smooth. Apple's own guidance is that bounce above about 0.4 "may feel
    /// too exaggerated for a UI element" and that bounce 0 is the most
    /// versatile general-purpose spring; the Dynamic-Island-style Mac apps are
    /// described as matching iOS's spring and damping ratios, and SwiftUI's
    /// default spring sits near bounce 0.175.
    ///
    /// So: a longer settle with a small, single overshoot. Fluidity here comes
    /// from duration and from continuity, not from bounce.
    ///
    /// **The overshoot still has a hard ceiling.** The panel window does not
    /// resize during the animation; the content animates inside a window only
    /// `NotchGeometry.shadowPadding` (24pt) taller than the open state and
    /// about 32pt wider each side. Bounce 0.16 stays well inside that.
    static var expand: Animation {
        isAnimated
            ? .spring(duration: 0.52, bounce: 0.16)
            : .linear(duration: 0.01)
    }

    /// Small, frequent changes — a live activity appearing, the closed width
    /// tracking a geometry change. Same family, tighter, and no overshoot:
    /// these fire often and a bounce on every one reads as instability.
    static var quick: Animation {
        isAnimated
            ? .spring(duration: 0.34, bounce: 0)
            : .linear(duration: 0.01)
    }

    /// Content inside the panel — page changes, sections appearing.
    ///
    /// Bounce 0 deliberately, on the same settle as `expand`. The shell may
    /// have a hint of overshoot; text and controls wobbling inside it is what
    /// reads as cheap. Matching the duration is what makes the two move as one
    /// body rather than as a box with a separate animation playing inside it.
    static var content: Animation {
        isAnimated
            ? .spring(duration: 0.52, bounce: 0)
            : .linear(duration: 0.01)
    }
}
