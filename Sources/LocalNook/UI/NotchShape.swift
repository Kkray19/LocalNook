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
    /// The system's Reduce Motion preference.
    ///
    /// Injectable for the same reason as the pointer and the mouse buttons:
    /// otherwise the one branch that matters — honouring it — can only be
    /// exercised on a machine that happens to have it switched on, and reports
    /// itself unverified everywhere else.
    nonisolated(unsafe) static var systemReducesMotion: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Honours both the app setting and the system Reduce Motion preference.
    static var isAnimated: Bool {
        let settings = Settings.shared
        guard settings.animationsEnabled else { return false }
        if settings.respectReducedMotion, systemReducesMotion() { return false }
        return true
    }

    /// The main open/close motion.
    ///
    /// Expressed as duration and bounce, the parameterisation Apple introduced
    /// in WWDC23.
    ///
    /// An earlier version of this comment asserted that `bounce` equals
    /// `1 - dampingFraction`. That relationship is *not* documented for these
    /// APIs and is withdrawn: `Spring` exposes both parameterisations and
    /// converts between them itself, but the conversion is not published, so
    /// nothing here should be justified by it. What is stated below are the
    /// parameters actually passed and the result actually observed.
    ///
    /// Tuning history, as parameters and observations rather than theory:
    ///
    ///   `.spring(response: 0.42, dampingFraction: 0.78)` — reported as
    ///   "very linear and not liquid, very blocky".
    ///   `.spring(response: 0.46, dampingFraction: 0.68)` — reported as
    ///   working, but wanted smoother.
    ///   `.spring(duration: 0.52, bounce: 0.16)` — current. Awaiting a verdict.
    ///
    /// Apple's stated guidance is that bounce above roughly 0.4 "may feel too
    /// exaggerated for a UI element" and that bounce 0 is the most versatile
    /// general-purpose spring. 0.16 sits well below that line deliberately: the
    /// fluidity here is meant to come from the settle and from continuity
    /// across interruptions, not from overshoot.
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

    /// `expand`, played backwards — the opening motion.
    ///
    /// Measured, not assumed. A recording of the installed app, sampled frame
    /// by frame, put the opening and the closing side by side as normalised
    /// progress:
    ///
    ///     elapsed   opening   closing reversed
    ///      0.25      0.242        0.091
    ///      0.50      0.566        0.255
    ///      0.75      0.862        0.593
    ///
    /// Same spring, opposite shapes. A spring is fast then slow, so running it
    /// forwards in both directions gives an open that leaps and a close that
    /// glides — and read backwards, the close is slow then fast. They are not
    /// the same trajectory and cannot be made so by tuning the parameters,
    /// which is why this exists.
    ///
    /// `1 - s(T - t)` is the definition of "played backwards": progress at time
    /// t is one minus the spring's own progress at the mirrored time. At t = T
    /// that is `1 - s(0)` = 1 exactly, so it lands on the target rather than
    /// approaching it. At t = 0 it is `1 - s(T)`, which for a spring with
    /// bounce is fractionally off zero — the mirror image of the settle at the
    /// end of the close, which is the point.
    static var expandReversed: Animation {
        isAnimated ? Animation(ReversedSpring(duration: 0.52, bounce: 0.16))
                   : .linear(duration: 0.01)
    }
}

/// Plays a spring backwards, so an opening can be a closing in reverse.
///
/// `Animation.spring` cannot express this: springs are asymmetric in time by
/// construction. `CustomAnimation` can, by sampling the spring at the mirrored
/// instant.
nonisolated struct ReversedSpring: CustomAnimation {
    let duration: TimeInterval
    let bounce: Double

    private var spring: Spring { Spring(duration: duration, bounce: bounce) }

    /// One minus the spring's progress at the mirrored time.
    ///
    /// Not private: this is the whole of the curve, and it is the thing worth
    /// asserting. The `animate` wrapper around it is bookkeeping.
    func progress(at time: TimeInterval) -> Double {
        let clamped = min(max(0, time), duration)
        return 1 - spring.value(target: 1.0, time: duration - clamped)
    }

    func animate<V: VectorArithmetic>(
        value: V, time: TimeInterval, context: inout AnimationContext<V>
    ) -> V? {
        guard time < duration else { return nil }
        return value.scaled(by: progress(at: time))
    }

    /// Reported so an interrupted open hands its speed to whatever interrupts
    /// it, rather than stopping dead and starting again. Differentiated
    /// numerically: the closed form of a reversed spring is not worth deriving
    /// for a value only used at the moment of an interruption.
    func velocity<V: VectorArithmetic>(
        value: V, time: TimeInterval, context: AnimationContext<V>
    ) -> V? {
        let step = 1.0 / 240.0
        let before = max(0, time - step), after = min(duration, time + step)
        guard after > before else { return nil }
        return value.scaled(by: (progress(at: after) - progress(at: before)) / (after - before))
    }
}

extension NotchMotion {
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
