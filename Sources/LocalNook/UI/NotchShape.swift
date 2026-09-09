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
    ///   `.spring(duration: 0.52, bounce: 0.16)` — current. Accepted for the
    ///   closing ("already looks right"), and accepted for the opening once
    ///   `OpeningMotion` stopped the landing snapping: "much better, I like
    ///   this version much more". Settled — do not tune further without a
    ///   fresh complaint to tune against.
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

    /// The opening motion: the closing spring read backwards, landing on a settle.
    ///
    /// Measured, not assumed. A recording of the installed app, sampled frame
    /// by frame, put the opening and the closing side by side as normalised
    /// progress. With the same spring run forwards in both directions they were
    /// a mean of 0.19 apart; reading the closing backwards brought that to
    /// 0.026. A spring is fast then slow, so run forwards in both directions it
    /// gives an open that leaps and a close that glides — and no choice of
    /// parameters fixes that, because the asymmetry *is* the spring.
    ///
    /// But a pure reversal lands badly, and for two reasons that were also
    /// measured rather than guessed:
    ///
    ///   * **It brakes.** The reversed curve stops accelerating at 83% of the
    ///     duration and falls from 4.97/s to 0.02/s over the last 90ms,
    ///     arriving at exactly 1.0 with no velocity left. That is a stop, not a
    ///     settle: the mirror image of a spring's launch, which is abrupt by
    ///     nature because nothing is meant to be watching it.
    ///   * **It was then truncated.** Ending the animation at the nominal
    ///     duration cut the last 60fps frame from 0.9819 straight to 1.0 — a
    ///     1.8% jump in one frame, about 10pt of width, at precisely the moment
    ///     the eye is on the edge that has stopped moving.
    ///
    /// So the approach is kept exactly as it was, and only the landing changes:
    /// at the instant the reversed path stops accelerating, it hands over to a
    /// spring that inherits its position *and* its speed. Continuous in both,
    /// so there is no seam — the shell carries its momentum through the full
    /// size, overshoots by about 1%, and settles. The settle uses the closing
    /// spring's own bounce, which is what makes the finish read as the same
    /// kind of motion rather than a decoration bolted on the end.
    static var expandOpening: Animation {
        isAnimated ? Animation(openingMotion) : .linear(duration: 0.01)
    }

    /// Built once.
    ///
    /// `expandOpening` is read from a view body, which runs on every frame of
    /// the animation it is describing. `OpeningMotion.init` samples the spring
    /// 240 times to find its peak velocity, so constructing one per read meant
    /// tens of thousands of spring evaluations a second for a value that never
    /// changes. Immutable and derived from constants, so sharing it is safe.
    ///
    /// A screen recording dropping frames mid-open is what sent me looking, but
    /// that turned out to be the recorder: the gaps are still there with this
    /// in place. The waste was real regardless.
    nonisolated(unsafe) private static let openingMotion = OpeningMotion(
        duration: 0.52, bounce: 0.16, settleDuration: 0.40
    )
}

/// The opening curve: a spring read backwards, then a spring that lands it.
///
/// `Animation.spring` can express neither half. Springs are asymmetric in time,
/// so reading one backwards needs sampling at the mirrored instant; and handing
/// over between two curves without a seam needs the second to start from the
/// first's velocity, which only a custom animation can arrange.
nonisolated struct OpeningMotion: CustomAnimation {
    /// The closing spring, whose reversal is the approach.
    let duration: TimeInterval
    let bounce: Double
    /// The settle that lands it. Same bounce as the closing spring, on purpose.
    let settleDuration: TimeInterval

    /// The instant the reversed approach stops accelerating, with the value and
    /// speed it has there. Computed once when the animation is created — the
    /// closed form of a spring's peak velocity is not published, and sampling
    /// 240 points costs less than a frame.
    private let handoverTime: TimeInterval

    private let handoverValue: Double
    private let handoverVelocity: Double

    init(duration: TimeInterval, bounce: Double, settleDuration: TimeInterval) {
        self.duration = duration
        self.bounce = bounce
        self.settleDuration = settleDuration

        let spring = Spring(duration: duration, bounce: bounce)
        func forward(_ time: TimeInterval) -> Double {
            spring.value(target: 1.0, time: max(0, time))
        }
        let step = 0.0005
        var peakTime = 0.0
        var peakVelocity = 0.0
        for sample in 0...240 {
            let time = duration * Double(sample) / 240
            let velocity = (forward(time + step) - forward(time - step)) / (2 * step)
            if velocity > peakVelocity {
                peakVelocity = velocity
                peakTime = time
            }
        }
        // Reversal maps the spring's peak velocity to the mirrored instant, and
        // the reversed curve's speed there is that same peak.
        handoverTime = duration - peakTime
        handoverValue = 1 - forward(peakTime)
        handoverVelocity = peakVelocity
    }

    /// The handover instant, for the checks that assert the seam is smooth.
    var handoverTimeForTesting: TimeInterval { handoverTime }

    private var closing: Spring { Spring(duration: duration, bounce: bounce) }
    private var settle: Spring { Spring(duration: settleDuration, bounce: bounce) }

    /// How long the whole thing runs. Not the nominal duration: ending on that
    /// is what produced the one-frame jump this exists to remove.
    var totalDuration: TimeInterval { handoverTime + settle.settlingDuration }

    /// Fraction of the travel covered at `time`.
    func progress(at time: TimeInterval) -> Double {
        let clock = max(0, time)
        guard clock >= handoverTime else {
            return 1 - closing.value(target: 1.0, time: duration - clock)
        }
        return settle.value(
            fromValue: handoverValue, toValue: 1.0,
            initialVelocity: handoverVelocity, time: clock - handoverTime
        )
    }

    func animate<V: VectorArithmetic>(
        value: V, time: TimeInterval, context: inout AnimationContext<V>
    ) -> V? {
        guard time < totalDuration else { return nil }
        return value.scaled(by: progress(at: time))
    }

    /// Reported so an interrupted open hands its speed to whatever interrupts
    /// it, rather than stopping dead and starting again.
    func velocity<V: VectorArithmetic>(
        value: V, time: TimeInterval, context: AnimationContext<V>
    ) -> V? {
        value.scaled(by: speed(at: time))
    }

    /// Rate of change of `progress`, differentiated numerically. Also what the
    /// handover is checked against: the two halves must agree here, or the seam
    /// is visible however well the positions line up.
    func speed(at time: TimeInterval) -> Double {
        let step = 1.0 / 2000
        let before = max(0, time - step)
        let after = time + step
        return (progress(at: after) - progress(at: before)) / (after - before)
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
