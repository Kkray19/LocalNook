//
//  AutomationPermission.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Whether this app is allowed to send Apple Events to another app — asked
//  without sending one, and without a dialog.
//
//  `AEDeterminePermissionToAutomateTarget` is public API (10.14+). With
//  `askUserIfNeeded: false` it answers from the TCC database and never prompts;
//  with `true` it is the deliberate request, which is what puts the app into
//  System Settings ▸ Privacy & Security ▸ Automation in the first place. That
//  entry does not exist until an app has asked at least once, which is why an
//  explicit "Connect" action is the only way for the user to get there.
//
//  This replaces a claim that was wrong: that consent could only be discovered
//  by sending an event and seeing it fail. It can be read directly, and the
//  difference matters — inferring "denied" from a failure conflates refusal
//  with never having asked, and any code that pokes a target to find out is a
//  code path that can raise a prompt the user did not ask for.
//
//  Verified on this machine (macOS 27.0): with `askUserIfNeeded: false` the
//  call returned immediately for a running target and raised no dialog, and
//  returned -600 for every target that was not running.
//

import AppKit
import CoreServices
import Foundation

nonisolated enum AutomationPermission {
    enum Status: Equatable, Sendable {
        /// Events to this target are allowed.
        case granted
        /// The user refused, or revoked it later.
        case denied
        /// Never asked. There is no System Settings entry yet.
        case notDetermined
        /// The target is not running, so the system will not answer. Says
        /// nothing about consent either way.
        case targetNotRunning
        /// Some other OSStatus. Kept rather than flattened, so a surprise shows
        /// up as itself in the probe instead of being read as a refusal.
        case other(OSStatus)

        var isGranted: Bool { self == .granted }

        var label: String {
            switch self {
            case .granted: "Connected"
            case .denied: "Refused"
            case .notDetermined: "Not requested"
            case .targetNotRunning: "Not running"
            case .other(let code): "Status \(code)"
            }
        }

        var permissionState: PermissionState {
            switch self {
            case .granted: .granted
            case .denied: .denied
            case .notDetermined: .notDetermined
            case .targetNotRunning, .other: .unknown
            }
        }
    }

    // MARK: Reading

    /// How long an answer is reused before it is refreshed.
    ///
    /// The underlying call is not cheap: measured on this machine at **12.6 ms**
    /// per call, consistently, over 200 calls — it is an XPC round trip to
    /// `tccd`, not a lookup. Both media views ask about both browsers while
    /// building their bodies, and the poll loop asks once a second, so calling
    /// through every time would put ~50 ms of blocking work into a frame that
    /// has 16 ms to spend. Consent also changes about as often as a person
    /// visits System Settings, so a few seconds of staleness costs nothing.
    static let cacheLifetime: TimeInterval = 5

    private struct Answer {
        var status: Status
        var readAt: Date
    }
    nonisolated(unsafe) private static var cache: [String: Answer] = [:]
    /// How many times the real system call has actually been made. The point of
    /// the cache is that this stays near zero however often the UI asks, and a
    /// counter says so deterministically where a stopwatch only says it
    /// probably did.
    nonisolated(unsafe) private static var determinations = 0
    nonisolated(unsafe) private static var refreshing: Set<String> = []
    private static let cacheLock = NSLock()
    private static let refreshQueue = DispatchQueue(
        label: "com.localnook.automation", qos: .utility
    )

    /// Reads consent. Never prompts, never sends an event to the target.
    ///
    /// Safe to call on every poll, and safe to call because the dashboard
    /// opened — which is the point. A provider that checks this before
    /// scripting cannot surprise the user with a dialog.
    ///
    /// Blocks only on the first question about a given app; after that it
    /// answers from the cache and refreshes behind the caller.
    static func status(forBundleID bundleID: String) -> Status {
        let now = Date()
        cacheLock.lock()
        let cached = cache[bundleID]
        cacheLock.unlock()

        if let cached {
            if now.timeIntervalSince(cached.readAt) < cacheLifetime { return cached.status }
            refreshInBackground(bundleID)
            return cached.status
        }
        return record(determine(bundleID: bundleID, askUserIfNeeded: false), for: bundleID)
    }

    private static func refreshInBackground(_ bundleID: String) {
        cacheLock.lock()
        let alreadyRunning = !refreshing.insert(bundleID).inserted
        cacheLock.unlock()
        guard !alreadyRunning else { return }

        refreshQueue.async {
            let status = determine(bundleID: bundleID, askUserIfNeeded: false)
            _ = record(status, for: bundleID)
            cacheLock.lock()
            refreshing.remove(bundleID)
            cacheLock.unlock()
        }
    }

    @discardableResult
    private static func record(_ status: Status, for bundleID: String) -> Status {
        cacheLock.lock()
        cache[bundleID] = Answer(status: status, readAt: Date())
        cacheLock.unlock()
        return status
    }

    /// Asks, showing the system dialog when consent has not been decided.
    ///
    /// Only ever from an explicit user action — the Connect button. Blocks
    /// while the dialog is up, so it must not be called on the main thread.
    /// Writes the outcome straight through, so the UI updates as soon as the
    /// dialog is dismissed rather than after the cache expires.
    static func request(forBundleID bundleID: String) -> Status {
        record(determine(bundleID: bundleID, askUserIfNeeded: true), for: bundleID)
    }

    /// Drops every cached answer. Used by the self-test, which must not carry
    /// state between runs.
    ///
    /// Waits for any refresh already in flight first. The queue is serial, so
    /// an empty block behind the pending work is enough — without it a refresh
    /// scheduled moments earlier would land after the cache was cleared and
    /// repopulate it, which is exactly the sort of leftover this exists to
    /// remove.
    static func forgetCachedAnswers() {
        refreshQueue.sync {}
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    /// Real system calls made so far, for the test that the cache holds.
    static var determinationCount: Int {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return determinations
    }

    private static func determine(bundleID: String, askUserIfNeeded: Bool) -> Status {
        cacheLock.lock(); determinations += 1; cacheLock.unlock()
        guard !bundleID.isEmpty else { return .other(OSStatus(paramErr)) }
        // A self-test must not consult, or create, real TCC state.
        guard !AppInfo.isSelfTest else { return .targetNotRunning }

        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        // The descriptor owns the AEDesc the call reads, so it has to outlive
        // the call rather than being released as the last use of `target`.
        let result: Status = withExtendedLifetime(target) { () -> Status in
            guard let descriptor = target.aeDesc else { return .other(OSStatus(paramErr)) }
            return interpret(AEDeterminePermissionToAutomateTarget(
                descriptor, typeWildCard, typeWildCard, askUserIfNeeded
            ))
        }
        return result
    }

    /// The OSStatus values this call actually returns, named.
    static func interpret(_ status: OSStatus) -> Status {
        switch status {
        case noErr: .granted
        case -1743: .denied            // errAEEventNotPermitted
        case -1744: .notDetermined     // errAEEventWouldRequireUserConsent
        case -600, -609: .targetNotRunning  // procNotFound, connectionInvalid
        default: .other(status)
        }
    }
}
