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
import AVFoundation
import EventKit
import UserNotifications

enum PermissionKind: String, CaseIterable, Identifiable {
    case accessibility
    case camera
    case calendar
    case notifications
    case automation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .camera: "Camera"
        case .calendar: "Calendar"
        case .notifications: "Notifications"
        case .automation: "Automation (Apple Events)"
        }
    }

    var usedFor: String {
        switch self {
        case .accessibility: "Reading media keys for the volume and brightness HUD."
        case .camera: "The Mirror widget. Video is previewed only, never recorded or written to disk."
        case .calendar: "Showing your upcoming events."
        case .notifications: "Alerting you when a timer finishes."
        case .automation: "Reading and controlling Music and Spotify playback."
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: "accessibility"
        case .camera: "web.camera"
        case .calendar: "calendar"
        case .notifications: "bell.badge"
        case .automation: "apple.terminal"
        }
    }

    /// Deep link into the matching System Settings privacy pane.
    var settingsURL: URL? {
        let anchor = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .camera: "Privacy_Camera"
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
            case .camera:
                states[kind] = Self.map(AVCaptureDevice.authorizationStatus(for: .video))
            case .calendar:
                states[kind] = Self.mapEvent(EKEventStore.authorizationStatus(for: .event))
            case .automation:
                // There is no read-only API for Automation consent; it only
                // becomes known once an Apple Event is actually sent.
                states[kind] = MediaScriptBridge.lastAutomationState
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

    private static func map(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
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
