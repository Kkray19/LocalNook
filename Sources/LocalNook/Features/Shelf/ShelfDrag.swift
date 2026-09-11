//
//  ShelfDrag.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  WHY THIS EXISTS
//
//  SwiftUI's `.onDrag` hands over exactly one `NSItemProvider`, so a row drag
//  can only ever carry one file. Gathering several files and dragging them out
//  together — the thing a handoff shelf is for — needs AppKit's
//  `beginDraggingSession(with:event:source:)` and one `NSDraggingItem` per file.
//
//  Row dragging is deliberately left as it was: one row, one file, through
//  SwiftUI. The multi-item drag is a separate, explicit affordance, because a
//  row drag that sometimes carries one file and sometimes carries eleven,
//  depending on a selection the pointer is not currently over, is a guess.
//
//  Nothing here copies a file to stage it. The Tray points at the user's files
//  where they are, and a drag hands over those same URLs; only items the Tray
//  itself created (dragged text) have a file of LocalNook's own, and that file
//  is the one it points at anyway.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Turning tray items into something another application will accept.
///
/// Pure, so every rule below can be asserted without a pasteboard, a window or
/// a gesture.
enum ShelfDrag {
    /// What one item can contribute to a drag, or nothing at all.
    ///
    /// A file that has since been moved or deleted contributes nothing: a drag
    /// that starts and then delivers an empty promise reads as the *receiving*
    /// app being broken, which is the worst possible place for the blame to
    /// land.
    static func url(for item: ShelfItem) -> URL? {
        switch item.kind {
        case .url:
            guard let payload = item.payload, let url = URL(string: payload) else { return nil }
            return url
        case .file, .folder, .image, .text:
            // `.text` included on purpose: LocalNook wrote it a real file when
            // it was dropped, so it hands over a file like everything else.
            guard item.stillExists, let url = item.url else { return nil }
            return url
        }
    }

    /// Everything draggable in the given items, in tray order, deduplicated.
    ///
    /// Two rows can point at one file — the same path can arrive by a drop and
    /// by a paste — and handing Finder the same URL twice makes it ask about
    /// replacing a file with itself.
    static func urls(for items: [ShelfItem]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for item in items {
            guard let url = url(for: item) else { continue }
            let key = url.isFileURL
                ? url.resolvingSymlinksInPath().standardizedFileURL.path
                : url.absoluteString
            if seen.insert(key).inserted { result.append(url) }
        }
        return result
    }

    /// How many of these cannot be handed over, so the Tray can say so rather
    /// than silently dragging fewer things than the user selected.
    static func missingCount(in items: [ShelfItem]) -> Int {
        items.reduce(0) { $0 + (url(for: $1) == nil ? 1 : 0) }
    }

    /// What to tell the user when some of what they picked cannot travel.
    static func exclusionNote(missing: Int, draggable: Int) -> String? {
        guard missing > 0 else { return nil }
        if draggable == 0 {
            return missing == 1 ? "That file is missing" : "All \(missing) files are missing"
        }
        return missing == 1 ? "1 missing file left out" : "\(missing) missing files left out"
    }
}

/// An invisible handle that starts a real multi-file dragging session.
///
/// Drawn by SwiftUI and overlaid with this, so the affordance keeps the panel's
/// own styling and only its mouse handling is AppKit's.
struct MultiFileDragHandle: NSViewRepresentable {
    /// Read at the moment the drag starts, not when the view is built, so it
    /// always reflects the selection as it is now.
    var urls: () -> [URL]
    var onBegin: () -> Void
    var onEnd: () -> Void
    /// Nothing could be handed over — say so instead of starting a dead drag.
    var onNothingToDrag: () -> Void

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        view.urls = urls
        view.onBegin = onBegin
        view.onEnd = onEnd
        view.onNothingToDrag = onNothingToDrag
    }

    @MainActor
    final class DragView: NSView, NSDraggingSource {
        var urls: () -> [URL] = { [] }
        var onBegin: () -> Void = {}
        var onEnd: () -> Void = {}
        var onNothingToDrag: () -> Void = {}

        private var pressed: NSEvent?

        /// How far the pointer must travel before this counts as a drag rather
        /// than a click that wobbled.
        static let threshold: CGFloat = 3

        /// LocalNook is an accessory app and is almost never the active one, so
        /// without this the first press would only bring the panel forward and
        /// the drag would need a second attempt.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) { pressed = event }

        override func mouseUp(with event: NSEvent) { pressed = nil }

        override func mouseDragged(with event: NSEvent) {
            guard let start = pressed else { return }
            let dx = event.locationInWindow.x - start.locationInWindow.x
            let dy = event.locationInWindow.y - start.locationInWindow.y
            guard (dx * dx + dy * dy).squareRoot() >= Self.threshold else { return }
            pressed = nil
            begin(with: start)
        }

        private func begin(with event: NSEvent) {
            let list = urls()
            guard !list.isEmpty else {
                onNothingToDrag()
                return
            }
            var dragging: [NSDraggingItem] = []
            for (index, url) in list.enumerated() {
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = url.isFileURL
                    ? NSWorkspace.shared.icon(forFile: url.path)
                    : NSWorkspace.shared.icon(for: .url)
                icon.size = NSSize(width: 32, height: 32)
                // Stacked with a slight cascade, the way Finder shows a
                // multi-file drag. Capped so fifty files do not draw a staircase
                // halfway down the screen.
                let step = CGFloat(min(index, 4)) * 4
                item.setDraggingFrame(
                    NSRect(x: bounds.midX - 16 + step, y: bounds.midY - 16 - step,
                           width: 32, height: 32),
                    contents: icon
                )
                dragging.append(item)
            }
            onBegin()
            beginDraggingSession(with: dragging, event: event, source: self)
        }

        // MARK: NSDraggingSource

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            // Copy, never move. The Tray points at files where they live; a
            // move would let the receiving app relocate an original out from
            // under the user because they dragged a *reference* to it.
            .copy
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            onEnd()
        }
    }
}
