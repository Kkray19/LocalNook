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

import CoreGraphics
import Foundation

/// Stage counters for hover, shared by both tracking views.
enum HoverProbe {
    /// `mouseEntered` / `mouseExited` callbacks AppKit actually delivered.
    nonisolated(unsafe) private(set) static var entersDelivered = 0
    nonisolated(unsafe) private(set) static var exitsDelivered = 0
    /// Times LocalNook forwarded a crossing to a view model.
    nonisolated(unsafe) private(set) static var handlerInvocations = 0
    /// Forwards that came from re-checking containment when a tracking area was
    /// rebuilt, rather than from a delivered crossing. Counted separately: the
    /// notch resizing under a still pointer is a different path from the pointer
    /// arriving, and conflating them makes `handled` disagree with `enters`.
    nonisolated(unsafe) private(set) static var containmentForwards = 0

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

    /// A forward triggered by a tracking-area rebuild finding the pointer
    /// already inside, not by a crossing.
    static func recordContainmentForward() {
        lock.lock(); handlerInvocations += 1; containmentForwards += 1; lock.unlock()
    }

    static func reset() {
        lock.lock()
        entersDelivered = 0
        exitsDelivered = 0
        handlerInvocations = 0
        containmentForwards = 0
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

    /// Seconds since the machine last saw any human input.
    ///
    /// Part of the provenance because it turned out to explain the thing the
    /// counters could not. A batch of twelve integration runs went eight clean
    /// and then four with `enters=0`, and three more runs immediately after
    /// were also `enters=0` — sticky, not intermittent. The variable that had
    /// changed was idle time: after a long unattended stretch the window server
    /// stops producing crossings for a window moved under a stationary pointer.
    /// Without this number in the line, that reads as a random platform flake
    /// and gets filed against the app.
    static var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: ~0)!
        )
    }

    /// Idle long enough that the window server is known to stop producing
    /// crossings for a window moved under a stationary pointer.
    ///
    /// Measured, not guessed: clean through 8 runs and then `enters=0` for 7
    /// consecutive runs once the machine had been untouched for roughly half an
    /// hour. The threshold below is deliberately conservative — it is a
    /// reporting aid, not a claim about where the boundary is.
    static let idleThreshold: Double = 300

    /// Why a run with no crossings is probably not about LocalNook.
    static var idleExplanation: String {
        let idle = idleSeconds
        guard idle >= idleThreshold else {
            return String(format: "The machine was in use (idle %.0fs), so idle "
                                + "state does not explain this.", idle)
        }
        return String(format: "The machine had been idle %.0fs; the window server "
                            + "stops delivering these crossings after a long "
                            + "unattended stretch. Re-run after using the mouse.", idle)
    }

    /// One-line provenance, printed with every hover result so a run that
    /// passed and a run that did not can be compared after the fact.
    static var summary: String {
        lock.lock()
        defer { lock.unlock() }
        return "enters=\(entersDelivered) exits=\(exitsDelivered) "
             + "handled=\(handlerInvocations) (of which containment=\(containmentForwards))"
             + String(format: " idle=%.0fs", idleSeconds)
    }

    /// Classifies an attempt from the counters and the resulting state.
    static func classify(placed: Bool, placementDetail: String, opened: Bool) -> Outcome {
        guard placed else { return .preconditionUnmet(placementDetail) }
        if opened { return .succeeded }
        if entersDelivered == 0 { return .noPlatformEvent }
        if handlerInvocations == 0 { return .eventDropped(enters: entersDelivered) }
        return .wrongState(handlerCalls: handlerInvocations)
    }

    /// The same classification for the leaving half of a crossing.
    ///
    /// The exit is subject to the identical platform limitation as the entry —
    /// AppKit is not obliged to deliver `mouseExited` when a *window* moves out
    /// from under a still pointer — and is observed to be the more frequent
    /// casualty of the two, since by then the panel is already moving. What a
    /// detached test panel does when no exit arrives is not a product
    /// postcondition: nothing owns it. The real contract, for a
    /// controller-owned notch, is asserted deterministically elsewhere.
    static func classifyExit(closed: Bool, entersSeen: Int) -> Outcome {
        if closed { return .succeeded }
        if exitsDelivered == 0 { return .noPlatformEvent }
        if handlerInvocations <= entersSeen { return .eventDropped(enters: exitsDelivered) }
        return .wrongState(handlerCalls: handlerInvocations)
    }
}
