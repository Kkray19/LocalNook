//
//  Permissions.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Every permission is requested lazily, at the moment the feature that needs
//  it is first used — never at launch. Nothing here triggers a system prompt on
//  its own; `status(of:)` is read-only.
//

import AppKit
import EventKit
import UserNotifications

enum PermissionKind: String, CaseIterable, Identifiable {
    case accessibility
    case calendar
    case notifications
    case automation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .calendar: "Calendar"
        case .notifications: "Notifications"
        case .automation: "Automation (Apple Events)"
        }
    }

    var usedFor: String {
        switch self {
        case .accessibility: "Not required for hover or the implemented volume HUD. Never requested by LocalNook."
        case .calendar: "Showing your upcoming events."
        case .notifications: "Alerting you when a timer finishes."
        case .automation: "Reading and controlling Music and Spotify playback."
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: "accessibility"
        case .calendar: "calendar"
        case .notifications: "bell.badge"
        case .automation: "apple.terminal"
        }
    }

    /// Deep link into the matching System Settings privacy pane.
    var settingsURL: URL? {
        let anchor = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .calendar: "Privacy_Calendars"
        case .notifications: "Notifications"
        case .automation: "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

enum PermissionState: Equatable {
    case granted
    case denied
    case notDetermined
    case unknown

    var label: String {
        switch self {
        case .granted: "Granted"
        case .denied: "Denied"
        case .notDetermined: "Not requested"
        case .unknown: "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .notDetermined: "circle.dashed"
        case .unknown: "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .granted: .green
        case .denied: .red
        case .notDetermined: .secondary
        case .unknown: .secondary
        }
    }
}

import SwiftUI

final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var states: [PermissionKind: PermissionState] = [:]

    private init() { refreshAll() }

    func refreshAll() {
        for kind in PermissionKind.allCases {
            switch kind {
            case .accessibility:
                states[kind] = AXIsProcessTrusted() ? .granted : .notDetermined
            case .calendar:
                states[kind] = Self.mapEvent(EKEventStore.authorizationStatus(for: .event))
            case .automation:
                states[kind] = Self.automationState()
            case .notifications:
                // Resolved asynchronously below, but seed a value now so the
                // dictionary always has an entry for every permission and the
                // UI never renders a missing row.
                if states[kind] == nil { states[kind] = .unknown }
            }
        }
        guard AppInfo.isRunningFromBundle else {
            states[.notifications] = .unknown
            return
        }
        Task { [weak self] in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let state: PermissionState = switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: .granted
            case .denied: .denied
            case .notDetermined: .notDetermined
            @unknown default: .unknown
            }
            self?.states[.notifications] = state
        }
    }

    /// Automation consent, read rather than provoked.
    ///
    /// It is per-target, and this row is one line, so it summarises: granted if
    /// any media app LocalNook talks to has said yes, refused if one has said
    /// no and none has said yes, otherwise not requested. The per-browser
    /// answer, which is the one that can be acted on, is shown in Settings ▸
    /// Media beside its own Connect button.
    ///
    /// A target that is not running cannot be asked about, so it contributes
    /// nothing either way; when nothing at all can be asked, the outcome of the
    /// most recent real Apple Event stands in.
    static func automationState() -> PermissionState {
        let targets = ["com.apple.Music", "com.spotify.client"]
            + MediaBrowser.allCases.map(\.bundleID)
        var sawDenied = false
        var sawAnswer = false
        for bundleID in targets {
            switch AutomationPermission.status(forBundleID: bundleID) {
            case .granted: return .granted
            case .denied: sawDenied = true; sawAnswer = true
            case .notDetermined: sawAnswer = true
            case .targetNotRunning, .other: break
            }
        }
        if sawDenied { return .denied }
        if sawAnswer { return .notDetermined }
        return MediaScriptBridge.lastAutomationState
    }

    private static func mapEvent(_ status: EKAuthorizationStatus) -> PermissionState {
        switch status {
        case .fullAccess: .granted
        // Write-only cannot read events, so the Calendar widget stays unusable.
        case .writeOnly: .denied
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    func open(_ kind: PermissionKind) {
        guard let url = kind.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}
