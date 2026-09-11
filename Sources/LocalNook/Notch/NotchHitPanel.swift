//
//  NotchHitPanel.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  WHY THIS EXISTS
//
//  Collapsed, the notch panel is a wide opaque strip lying across the menu bar —
//  wider still when a live activity is showing, which stretches it to ~445pt.
//  Any click it accepts is a click the menu bar, Chrome or anything else at the
//  top of the screen never sees.
//
//  Declining the hit test in the content view is not enough to fix that.
//  `NSWindow` finds its target view via `hitTest`, and when that returns nil the
//  event is simply not dispatched — it is *not* handed to the window below. The
//  click is swallowed silently, which looks identical to the bug.
//
//  The mechanism that genuinely routes events past a window is
//  `ignoresMouseEvents`, and that is all-or-nothing per window. So interaction
//  and drawing are split across two windows:
//
//    • this one — tiny, invisible, exactly the notch, and the only window that
//      accepts input while collapsed;
//    • the main panel — as wide as it needs to be to draw, and completely inert
//      while collapsed.
//
//  While the notch is open the roles swap: the main panel is visible and covers
//  real content, so it takes input, and this one steps aside.
//

import OSLog
import AppKit
import UniformTypeIdentifiers

/// Invisible input catcher sized to the collapsed notch.
final class NotchHitPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Just above the main panel, so the notch itself always wins over the
        // decorative wings drawn behind it.
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isRestorable = false
        acceptsMouseMovedEvents = true
        // Nothing is drawn here, so keep it out of screenshots.
        sharingType = .none
    }
}

/// The catcher's content: reports hover, clicks and drags for the notch.
final class NotchHitView: NSView {

    var onHoverChange: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var onDragEnter: (() -> Void)?
    /// Called when the drag leaves, is dropped, or is cancelled. Previously
    /// `draggingExited` did nothing at all, so a drag that entered and left
    /// without dropping left the notch open with nothing to close it.
    var onDragEnd: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isInside = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Accepting drags here keeps "drag files onto the notch" working while
        // the main panel is inert.
        registerForDraggedTypes([.fileURL, .URL, .string, .png, .tiff])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // `.activeAlways` because LocalNook is an accessory app and is almost
        // never frontmost.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area

        // The pointer can already be inside when the area is rebuilt, e.g. after
        // the notch resizes under a stationary cursor.
        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let nowInside = bounds.contains(point)
            if nowInside != isInside {
                isInside = nowInside
                HoverProbe.recordContainmentForward()
                let r = window.convertToScreen(convert(bounds, to: nil))
                let p = NSEvent.mouseLocation
                HoverTracker.logger.debug("catcher containment inside=\(nowInside, privacy: .public) catcher=\("\(Int(r.minX))..\(Int(r.maxX)) y\(Int(r.minY))..\(Int(r.maxY))", privacy: .public) pointer=\(Int(p.x), privacy: .public),\(Int(p.y), privacy: .public)")
                onHoverChange?(nowInside)
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        HoverProbe.recordEnter()
        guard !isInside else { return }
        HoverTracker.logger.debug("catcher mouseEntered")
        isInside = true
        HoverProbe.recordHandlerCall()
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        HoverProbe.recordExit()
        guard isInside else { return }
        isInside = false
        HoverProbe.recordHandlerCall()
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    // MARK: Dragging

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onDragEnter?()
        // The notch opens and the main panel takes over the actual drop.
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragEnd?()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDragEnd?()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { onDragEnd?() }
        // Once open, the expanded panel owns the drop target; if the drop lands
        // here first, hand it to the shelf directly so nothing is lost.
        // Recognised, not merely new: reporting failure for a duplicate makes
        // AppKit play the rejection animation for a perfectly good drop.
        return ShelfStore.shared.ingestReportingOutcome(sender.draggingPasteboard).wasHandled
    }
}
