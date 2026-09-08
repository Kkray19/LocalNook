//
//  NotchHitTestView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  WHY THIS EXISTS
//
//  The notch panel is a transparent overlay pinned across the top of the screen,
//  above the menu bar. Anything it hit-tests, it steals: a click that lands on
//  the panel never reaches Chrome, the menu bar, or whatever is underneath.
//
//  `NSHostingView` hit-tests to itself for *every* point inside its bounds,
//  regardless of whether SwiftUI drew anything there. Marking the SwiftUI
//  content `.allowsHitTesting(false)` does not change that — AppKit never asks
//  SwiftUI. So a transparent 900pt-wide panel silently swallows the entire top
//  strip of the display.
//
//  This container fixes that at the only layer that can: it declines the hit
//  test outright for points outside the region LocalNook is actually drawing
//  something interactive in, which lets the event fall through to the window
//  below.
//
//  Tracking areas are unaffected — they are delivered by the window server
//  independently of hit testing — so hover still works everywhere it should.
//

import AppKit

/// Hosts the notch UI and restricts which points accept clicks.
final class NotchHitTestView: NSView {
    /// The region, in this view's own coordinates, that should accept clicks.
    ///
    /// Everything outside it passes through to whatever is underneath. Returning
    /// `.zero` makes the panel entirely click-through.
    var interactiveRegion: () -> NSRect = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the superview's coordinate system.
        let local = superview.map { convert(point, from: $0) } ?? point
        guard interactiveRegion().contains(local) else { return nil }
        return super.hitTest(point)
    }

    /// The panel is never opaque; this keeps AppKit from short-circuiting.
    override var isOpaque: Bool { false }
}
