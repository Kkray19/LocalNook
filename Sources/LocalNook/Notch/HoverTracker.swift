//
//  HoverTracker.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  WHY THIS EXISTS
//
//  The obvious way to detect the pointer reaching the notch is a global event
//  monitor:
//
//      NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { ... }
//
//  On macOS 27 that monitor **never fires** unless the app has been granted
//  Accessibility. Measured directly: with `AXIsProcessTrusted() == false`, a
//  global `.mouseMoved` monitor received 0 of 12 synthesised moves.
//
//  LocalNook must not require Accessibility just to open on hover, so hover is
//  detected with an `NSTrackingArea` on our own view instead. Tracking areas
//  are delivered by the window server to the window that owns them and need no
//  permission at all.
//
//  The area is sized to the interactive region — the notch itself when
//  collapsed, the whole panel when expanded — because the panel is far wider
//  than the visible notch and tracking all of it would trigger on any pointer
//  passing near the top of the screen.
//

import OSLog
import AppKit
import SwiftUI

/// A transparent view that reports pointer enter/exit for an exact rectangle.
struct HoverTracker: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onChange = onChange
    }

    /// Debug-level trail for the running app; see NotchTransitionLog.logger.
    nonisolated static let logger = Logger(subsystem: "com.localnook.app", category: "hover")

    /// Diagnostic trail, read by `--self-test`. Empty in normal operation.
    nonisolated(unsafe) static var diagnostics: [String] = []

    static func record(_ message: @autoclosure () -> String) {
        guard AppInfo.isSelfTest else { return }
        if diagnostics.count >= 200 { diagnostics.removeFirst() }
        diagnostics.append(message())
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var trackingArea: NSTrackingArea?
        private var isInside = false

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }

            // `.activeAlways` matters: LocalNook is an accessory app and is
            // almost never the active application, so `.activeInActiveApp`
            // would mean hover effectively never fires.
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
            let inScreen = window.map { w in "\(w.convertToScreen(convert(bounds, to: nil)))" } ?? "no window"
            HoverTracker.record("area bounds=\(bounds) screen=\(inScreen)")

            // The pointer can already be inside when the area is rebuilt, e.g.
            // after the notch resizes under a stationary cursor.
            if let window {
                let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                let nowInside = bounds.contains(point)
                if nowInside != isInside {
                    isInside = nowInside
                    HoverProbe.recordContainmentForward()
                    let r = window.convertToScreen(convert(bounds, to: nil))
                    let p = NSEvent.mouseLocation
                    HoverTracker.logger.debug("panel containment inside=\(nowInside, privacy: .public) tracker=\("\(Int(r.minX))..\(Int(r.maxX)) y\(Int(r.minY))..\(Int(r.maxY))", privacy: .public) pointer=\(Int(p.x), privacy: .public),\(Int(p.y), privacy: .public)")
                    onChange?(nowInside)
                }
            }
        }

        override func mouseEntered(with event: NSEvent) {
            HoverProbe.recordEnter()
            // AppKit re-sends this every time the tracking area is rebuilt,
            // which happens on every frame of the open animation as the notch
            // grows. Only a genuine transition should reach `onChange`.
            guard !isInside else { return }
            HoverTracker.logger.debug("panel mouseEntered")
            HoverTracker.record("mouseEntered")
            isInside = true
            HoverProbe.recordHandlerCall()
            onChange?(true)
        }

        override func mouseExited(with event: NSEvent) {
            HoverProbe.recordExit()
            guard isInside else { return }
            HoverTracker.record("mouseExited")
            isInside = false
            HoverProbe.recordHandlerCall()
            onChange?(false)
        }

        /// Never swallow clicks meant for the app underneath.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
