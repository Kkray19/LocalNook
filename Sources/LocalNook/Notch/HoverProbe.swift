//
//  HoverProbe.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Attribution for hover failures.
//
//  "Hover did not open the notch" has four quite different causes, and telling
//  them apart matters because only two of them are LocalNook's fault:
//
//    1. The test never got the panel under the pointer.        (precondition)
//    2. AppKit delivered no tracking event.                    (platform)
//    3. LocalNook got the event and did nothing with it.        (defect)
//    4. LocalNook handled it but the state came out wrong.      (defect)
//
//  Counting each stage separately turns a guess into a diagnosis. The counters
//  are metadata only — how many events arrived, not where the pointer was or
//  what the user was doing.
//

import Foundation

/// Stage counters for hover, shared by both tracking views.
enum HoverProbe {
    /// `mouseEntered` / `mouseExited` callbacks AppKit actually delivered.
    nonisolated(unsafe) private(set) static var entersDelivered = 0
    nonisolated(unsafe) private(set) static var exitsDelivered = 0
    /// Times LocalNook forwarded a crossing to a view model.
    nonisolated(unsafe) private(set) static var handlerInvocations = 0

    private static let lock = NSLock()

    static func recordEnter() {
        lock.lock(); entersDelivered += 1; lock.unlock()
    }

    static func recordExit() {
        lock.lock(); exitsDelivered += 1; lock.unlock()
    }

    static func recordHandlerCall() {
        lock.lock(); handlerInvocations += 1; lock.unlock()
    }

    static func reset() {
        lock.lock()
        entersDelivered = 0
        exitsDelivered = 0
        handlerInvocations = 0
        lock.unlock()
    }

    /// Where a hover attempt broke down.
    enum Outcome: Equatable {
        /// The panel never got under the pointer; nothing was exercised.
        case preconditionUnmet(String)
        /// AppKit produced no crossing to react to.
        case noPlatformEvent
        /// A crossing arrived but was not forwarded.
        case eventDropped(enters: Int)
        /// It was forwarded but the state is wrong.
        case wrongState(handlerCalls: Int)
        case succeeded

        var isLocalNookDefect: Bool {
            switch self {
            case .eventDropped, .wrongState: true
            case .preconditionUnmet, .noPlatformEvent, .succeeded: false
            }
        }
    }

    /// One-line provenance, printed with every hover result so a run that
    /// passed and a run that did not can be compared after the fact.
    static var summary: String {
        lock.lock()
        defer { lock.unlock() }
        return "enters=\(entersDelivered) exits=\(exitsDelivered) handled=\(handlerInvocations)"
    }

    /// Classifies an attempt from the counters and the resulting state.
    static func classify(placed: Bool, placementDetail: String, opened: Bool) -> Outcome {
        guard placed else { return .preconditionUnmet(placementDetail) }
        if opened { return .succeeded }
        if entersDelivered == 0 { return .noPlatformEvent }
        if handlerInvocations == 0 { return .eventDropped(enters: entersDelivered) }
        return .wrongState(handlerCalls: handlerInvocations)
    }
}
