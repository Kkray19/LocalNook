//
//  NotchGesture.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Two-finger swipe over the notch: down to open, up to close.
//
//  ── Why a recogniser rather than a raw delta ───────────────────────────────
//
//  A trackpad swipe arrives as a stream of `scrollWheel` events, not one
//  gesture. Acting on each would open and close the notch a dozen times in a
//  flick. So travel is accumulated across the gesture and a direction is
//  emitted exactly once, when the net movement first crosses a threshold; the
//  rest of the gesture, including its momentum tail, is ignored until the
//  fingers lift. This is a pure value type so the thresholding — the part that
//  is easy to get subtly wrong — is tested without a trackpad.
//
//  ── The one thing hardware decides ─────────────────────────────────────────
//
//  Which finger direction a positive `scrollingDeltaY` means depends on the
//  "natural scrolling" setting, which AppKit reports per event as
//  `isDirectionInvertedFromDevice`. That is honoured here so the gesture
//  follows the fingers, not the pixels, whichever way scrolling is set. See
//  Settings.swipeToToggle for the switch, and NotchViewModel.handleSwipe for
//  what a direction does.
//

import Foundation

nonisolated enum SwipeDirection: Equatable, Sendable { case up, down }

/// The part of a scroll stream a gesture recogniser cares about.
nonisolated enum ScrollStreamPhase: Equatable, Sendable {
    /// A trackpad gesture beginning, changing, or in its momentum tail.
    case began, changed, momentum, ended
    /// A legacy mouse wheel, which has no phases at all — each tick is discrete.
    case discrete
}

/// Accumulates a scroll stream into at most one swipe direction per gesture.
nonisolated struct SwipeAccumulator: Equatable, Sendable {
    /// Net vertical travel, in points, before a swipe registers. Large enough
    /// that an incidental scroll over the notch is not read as a command.
    var threshold: CGFloat = 18

    private(set) var accumulated: CGFloat = 0
    private(set) var firedThisGesture = false

    /// Feeds one scroll event. Returns a direction the first time a gesture's
    /// net travel crosses the threshold, and nil every other time.
    mutating func feed(
        deltaY: CGFloat, phase: ScrollStreamPhase, invertedFromDevice: Bool
    ) -> SwipeDirection? {
        switch phase {
        case .began:
            // A new gesture starts clean, so a previous flick's leftover travel
            // cannot carry into it.
            accumulated = 0
            firedThisGesture = false
        case .ended:
            accumulated = 0
            firedThisGesture = false
            return nil
        case .changed, .momentum, .discrete:
            break
        }

        accumulated += deltaY
        // One command per gesture: once a direction has fired, the rest of the
        // travel — especially the momentum tail — is swallowed until the fingers
        // lift and a new gesture begins.
        guard !firedThisGesture, abs(accumulated) >= threshold else { return nil }
        firedThisGesture = true

        // Follow the fingers, not the content. With natural scrolling on
        // (inverted), moving the fingers down produces a positive delta.
        let fingersMovedDown = invertedFromDevice ? accumulated > 0 : accumulated < 0
        return fingersMovedDown ? .down : .up
    }
}
