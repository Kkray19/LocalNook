//
//  RenderServerAnimation.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  WHY THIS EXISTS
//
//  SwiftUI's `.repeatForever` never becomes quiescent. The view graph reports
//  pending work on every display-link tick, so AppKit lays the whole hosting
//  view out and SwiftUI rebuilds its display list at the refresh rate — 120
//  times a second on this hardware — for as long as the animation is on screen.
//  It does that regardless of how small the animated thing is, because the cost
//  is the pass over the tree, not the pixels.
//
//  Measured, collapsed, with one 11pt spinner showing: 12.6% of a core, all of
//  it inside `NSHostingView.layout()` and `DisplayList.ViewUpdater`, with no
//  LocalNook frame anywhere on the stack. The same build with that one
//  animation suppressed sat at 0.4%.
//
//  Core Animation does not work that way. An animation added to a layer is
//  handed to the window server once and interpolated there. The app process
//  sleeps through every frame of it; the render server also stops interpolating
//  by itself when the window is occluded or the display sleeps, which is
//  exactly the "stop when nobody can see it" behaviour we would otherwise have
//  to write and test ourselves.
//
//  So the two indefinite progress indicators animate as layers. Everything with
//  an end — opening, closing, transitions — stays in SwiftUI, where a finite
//  animation settles and the view graph goes quiet again on its own.
//

import AppKit
import SwiftUI

/// Shared plumbing: a layer-backed view that keeps one repeating animation
/// alive for exactly as long as it is in a window.
///
/// Detaching a layer tree from its window drops its animations, so the
/// animation is (re)installed from `viewDidMoveToWindow` rather than once at
/// construction — otherwise the indicator comes back static after the notch has
/// been closed and reopened.
class RenderServerAnimatedView: NSView {
    /// Whether motion is wanted at all. Reduce Motion keeps the shape and
    /// drops the movement, which is the same bargain the SwiftUI version made.
    var animated = true

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { removeRepeatingAnimations() } else { installAnimations() }
    }

    /// Subclasses add their `CAAnimation`s here. Called whenever the view
    /// enters a window, so it must be safe to call more than once.
    func installAnimations() {}

    func removeRepeatingAnimations() {}

    /// Layer geometry is set in `layout`, not at construction, because SwiftUI
    /// sizes the representable after it is made.
    override func layout() {
        super.layout()
        // Frame changes must not animate implicitly: the whole point is that
        // the only animations on these layers are the ones we installed.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutLayers()
        CATransaction.commit()
    }

    func layoutLayers() {}
}

// MARK: - Turning arc

/// A turning arc: something is working, without saying what about.
///
/// Under Reduce Motion it becomes a plain ring — the indicator still says
/// "busy", it just does not spin to say it.
struct SpinningArc: NSViewRepresentable {
    var tint: Color
    /// Fraction of the circle the arc covers.
    var portion: CGFloat = 0.72
    var diameter: CGFloat = 11
    var lineWidth: CGFloat = 2
    /// Seconds for one full turn.
    var period: Double = 0.9
    var animated: Bool = true

    func makeNSView(context: Context) -> ArcView { ArcView() }

    func updateNSView(_ view: ArcView, context: Context) {
        view.apply(tint: tint, portion: portion, lineWidth: lineWidth,
                   period: period, animated: animated)
    }

    @MainActor
    final class ArcView: RenderServerAnimatedView {
        private let track = CAShapeLayer()
        private let arc = CAShapeLayer()
        private var period: Double = 0.9
        private var lineWidth: CGFloat = 2
        private var portion: CGFloat = 0.72
        private static let key = "com.localnook.spin"

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            for shape in [track, arc] {
                shape.fillColor = nil
                shape.lineCap = .round
                layer?.addSublayer(shape)
            }
            // The faint full ring the arc turns inside.
            track.strokeColor = NSColor.white.withAlphaComponent(0.16).cgColor
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        func apply(tint: Color, portion: CGFloat, lineWidth: CGFloat,
                   period: Double, animated: Bool) {
            arc.strokeColor = NSColor(tint).cgColor
            let changed = self.period != period || self.animated != animated
            self.portion = portion
            self.lineWidth = lineWidth
            self.period = period
            self.animated = animated
            needsLayout = true
            // Restarting a running spin on every SwiftUI update would make it
            // stutter, so only a genuine change to the motion reinstalls it.
            if changed {
                removeRepeatingAnimations()
                if window != nil { installAnimations() }
            }
        }

        override func layoutLayers() {
            let side = min(bounds.width, bounds.height)
            let square = CGRect(
                x: (bounds.width - side) / 2, y: (bounds.height - side) / 2,
                width: side, height: side
            )
            let path = CGPath(ellipseIn: square.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                              transform: nil)
            for shape in [track, arc] {
                shape.frame = bounds
                shape.path = path
                shape.lineWidth = lineWidth
                // Rotation has to be about the middle of the circle, which is
                // the middle of the view.
                shape.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
                shape.bounds = bounds
            }
            arc.strokeEnd = portion
        }

        override func installAnimations() {
            guard animated, arc.animation(forKey: Self.key) == nil else { return }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = 2 * Double.pi
            spin.duration = period
            spin.repeatCount = .greatestFiniteMagnitude
            spin.isRemovedOnCompletion = false
            spin.timingFunction = CAMediaTimingFunction(name: .linear)
            arc.add(spin, forKey: Self.key)
        }

        override func removeRepeatingAnimations() {
            arc.removeAnimation(forKey: Self.key)
        }

        // MARK: Seams for the lifecycle checks

        var spinAnimation: CAAnimation? { arc.animation(forKey: Self.key) }
        var hasSpin: Bool { spinAnimation != nil }
        var spinIsRepeating: Bool { (spinAnimation?.repeatCount ?? 0) > 1 }
        /// The animation is on a layer, which is what puts it in the render
        /// server rather than in the app's view graph.
        var spinIsOnALayer: Bool {
            (spinAnimation as? CABasicAnimation)?.keyPath == "transform.rotation.z"
        }
    }
}

// MARK: - Marching bar

/// The progress line the agents show while they are working. Decorative: it
/// says "still going", not how far along.
struct MarchingBar: NSViewRepresentable {
    var tint: Color
    var trackTint: Color
    /// Width of the moving segment, as a fraction of the track.
    var fraction: CGFloat = 0.45
    /// How far the segment travels each way, as a fraction of the track.
    var travel: CGFloat = 0.62
    var period: Double = 0.9
    var animated: Bool = true

    func makeNSView(context: Context) -> BarView { BarView() }

    func updateNSView(_ view: BarView, context: Context) {
        view.apply(tint: tint, trackTint: trackTint, fraction: fraction,
                   travel: travel, period: period, animated: animated)
    }

    @MainActor
    final class BarView: RenderServerAnimatedView {
        private let segment = CALayer()
        private var fraction: CGFloat = 0.45
        private var travel: CGFloat = 0.62
        private var period: Double = 0.9
        private static let key = "com.localnook.march"

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            // The segment slides out past both ends and is clipped by the
            // track, exactly as the SwiftUI version was clipped by its capsule.
            layer?.masksToBounds = true
            layer?.addSublayer(segment)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        func apply(tint: Color, trackTint: Color, fraction: CGFloat,
                   travel: CGFloat, period: Double, animated: Bool) {
            segment.backgroundColor = NSColor(tint).cgColor
            layer?.backgroundColor = NSColor(trackTint).cgColor
            let changed = self.period != period || self.animated != animated
                || self.fraction != fraction || self.travel != travel
            self.fraction = fraction
            self.travel = travel
            self.period = period
            self.animated = animated
            needsLayout = true
            if changed {
                removeRepeatingAnimations()
                if window != nil { installAnimations() }
            }
        }

        override func layoutLayers() {
            layer?.cornerRadius = bounds.height / 2
            let width = bounds.width * fraction
            segment.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            segment.cornerRadius = bounds.height / 2
            segment.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            segment.position = CGPoint(x: startX, y: bounds.midY)
        }

        /// Leading edge at `-travel × width`, matching the offset the SwiftUI
        /// version animated, converted to the layer's centre.
        private var startX: CGFloat {
            -travel * bounds.width + bounds.width * fraction / 2
        }

        private var endX: CGFloat {
            travel * bounds.width + bounds.width * fraction / 2
        }

        override func installAnimations() {
            guard animated, bounds.width > 0,
                  segment.animation(forKey: Self.key) == nil else { return }
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = startX
            slide.toValue = endX
            slide.duration = period
            slide.autoreverses = true
            slide.repeatCount = .greatestFiniteMagnitude
            slide.isRemovedOnCompletion = false
            slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            segment.add(slide, forKey: Self.key)
        }

        override func removeRepeatingAnimations() {
            segment.removeAnimation(forKey: Self.key)
        }

        // MARK: Seams for the lifecycle checks

        var marchAnimation: CAAnimation? { segment.animation(forKey: Self.key) }
        var hasMarch: Bool { marchAnimation != nil }
        var marchAutoreverses: Bool { marchAnimation?.autoreverses ?? false }

        /// The animation cannot be installed until the view has a width, and
        /// SwiftUI sizes it after it is put in a window.
        override func layout() {
            super.layout()
            if window != nil { installAnimations() }
        }
    }
}
