//
//  MediaScriptBridge.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Talks to media apps over Apple Events (AppleScript). This is a public,
//  documented, user-consented mechanism — LocalNook deliberately does not link
//  the private MediaRemote framework, and ships no prebuilt binaries.
//
//  Trade-off, recorded honestly: Apple Events only reach apps that expose a
//  scripting dictionary (Music, Spotify, VLC…). Browser tabs and other
//  Now Playing sources are not visible this way. `MediaProvider` exists so an
//  additional provider can be dropped in later without touching the UI.
//

import AppKit
import Foundation

/// Result of one scripting round-trip.
struct ScriptResult: Sendable {
    let lines: [String]
    let errorNumber: Int?

    /// -1743 is "not authorised to send Apple Events"; -600 is "app not running".
    var isAuthorizationFailure: Bool { errorNumber == -1743 }
    var isNotRunning: Bool { errorNumber == -600 || errorNumber == -609 }
}

/// Executes AppleScript off the main thread on a single dedicated queue.
///
/// `NSAppleScript` is not thread-safe, so every execution is funnelled through
/// one serial queue; scripts are compiled once and reused, which keeps a poll
/// down to a few milliseconds.
nonisolated final class MediaScriptBridge: @unchecked Sendable {
    static let shared = MediaScriptBridge()

    /// Automation consent is only observable *after* an event is sent, so the
    /// Privacy pane reads the outcome of the most recent attempt.
    nonisolated(unsafe) private static var _lastAutomationState: PermissionState = .notDetermined
    private static let stateLock = NSLock()

    static var lastAutomationState: PermissionState {
        stateLock.lock(); defer { stateLock.unlock() }
        return _lastAutomationState
    }

    private static func recordAutomation(_ state: PermissionState) {
        stateLock.lock(); _lastAutomationState = state; stateLock.unlock()
    }

    private let queue = DispatchQueue(label: "com.localnook.applescript", qos: .utility)
    private var compiled: [String: NSAppleScript] = [:]
    private let cacheLock = NSLock()

    private init() {}

    /// Runs `source` and returns its newline-separated output.
    func run(_ source: String) async -> ScriptResult {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: ScriptResult(lines: [], errorNumber: nil))
                    return
                }
                continuation.resume(returning: self.runSync(source))
            }
        }
    }

    private func runSync(_ source: String) -> ScriptResult {
        let script: NSAppleScript?
        cacheLock.lock()
        if let existing = compiled[source] {
            script = existing
        } else {
            let created = NSAppleScript(source: source)
            if compiled.count >= 32 { compiled.removeAll(keepingCapacity: true) }
            compiled[source] = created
            script = created
        }
        cacheLock.unlock()

        guard let script else { return ScriptResult(lines: [], errorNumber: nil) }

        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)

        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int
            if number == -1743 {
                Self.recordAutomation(.denied)
            }
            return ScriptResult(lines: [], errorNumber: number)
        }

        Self.recordAutomation(.granted)
        if descriptor.numberOfItems == 6 {
            // Apple Events keep numeric descriptors independent of locale.
            let fields = (1...6).map { index in
                index >= 5 ? String(descriptor.atIndex(index)?.doubleValue ?? 0)
                    : (descriptor.atIndex(index)?.stringValue ?? "")
            }
            return ScriptResult(lines: fields, errorNumber: nil)
        }
        let text = descriptor.stringValue ?? ""
        return ScriptResult(
            lines: text.components(separatedBy: "\n"),
            errorNumber: nil
        )
    }

    /// Whether an app is installed, checked without launching it.
    static func isInstalled(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Whether an app is currently running, checked without launching it.
    static func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}
