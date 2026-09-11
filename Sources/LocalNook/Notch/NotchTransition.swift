//
//  NotchTransition.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Provenance for open/close transitions.
//
//  A window changing size proves only that *something* opened the notch. It does
//  not distinguish a physical hover from a scripted command or from the
//  once-a-second fallback — a distinction that matters when deciding whether
//  hover has actually been demonstrated, and when diagnosing a notch that will
//  not stay put.
//
//  The log records the cause, the display and the window, and nothing else. No
//  file names, no window titles, no user content ever enters it.
//

import OSLog
import AppKit
import Foundation

/// What caused a notch to open or close.
enum NotchTransitionSource: String, Sendable {
    /// An `NSTrackingArea` callback — a real pointer crossing.
    case trackingArea
    /// A distributed notification or the menu bar item.
    case explicitCommand
    /// The once-a-second recovery check. Should be rare in normal use.
    case pointerFallback
    /// Escape key.
    case escape
    /// A click outside the panel.
    case outsideClick
    /// A drag arriving over the notch.
    case drag
    /// A two-finger swipe over the notch.
    case gesture
    /// Fullscreen suppression, lock, or wake.
    case systemState
    /// Called directly in a test.
    case programmatic

    var label: String { rawValue }
}

/// One recorded transition. Metadata only.
struct NotchTransition: Sendable, Equatable {
    let at: Date
    let opened: Bool
    let source: NotchTransitionSource
    /// Stable display id, truncated — enough to tell displays apart.
    let displayID: String
    let windowNumber: Int

    var line: String {
        let time = at.formatted(date: .omitted, time: .standard)
        return "\(time)  \(opened ? "open " : "close")  via \(source.label)  display \(displayID)  window \(windowNumber)"
    }
}

/// Bounded, in-memory transition log.
///
/// Deliberately not written to disk: it exists to answer "what just moved the
/// notch?" during a session, not to build a history of the user's behaviour.
enum NotchTransitionLog {
    private static let limit = 120
    /// Debug level, so it is neither stored nor paid for unless someone is
    /// streaming it: `log stream --level debug --predicate 'subsystem ==
    /// "com.localnook.app"'`. The in-memory log below belongs to the running
    /// process, so this is the only way to see from outside what moved the
    /// notch — which is what diagnosing a live hover problem needs.
    nonisolated static let logger = Logger(subsystem: "com.localnook.app", category: "transitions")
    nonisolated(unsafe) private static var entries: [NotchTransition] = []
    private static let lock = NSLock()

    static func record(
        opened: Bool,
        source: NotchTransitionSource,
        displayID: String?,
        windowNumber: Int
    ) {
        let entry = NotchTransition(
            at: Date(),
            opened: opened,
            source: source,
            displayID: displayID.map { String($0.prefix(8)) } ?? "—",
            windowNumber: windowNumber
        )
        lock.lock()
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        lock.unlock()
        logger.debug("\(opened ? "open" : "close", privacy: .public) via \(source.label, privacy: .public)")
    }

    static var all: [NotchTransition] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    static func count(of source: NotchTransitionSource) -> Int {
        all.filter { $0.source == source }.count
    }

    static func clear() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }

    /// Human-readable dump for `--transitions`.
    static var report: String {
        let all = self.all
        guard !all.isEmpty else { return "no transitions recorded" }
        var text = all.map(\.line).joined(separator: "\n")
        text += "\n\nby source:"
        for source in [
            NotchTransitionSource.trackingArea, .explicitCommand, .pointerFallback,
            .escape, .outsideClick, .drag, .gesture, .systemState, .programmatic
        ] {
            let n = count(of: source)
            if n > 0 { text += "\n  \(source.label): \(n)" }
        }
        return text
    }
}
