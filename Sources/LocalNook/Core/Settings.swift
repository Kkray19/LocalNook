//
//  Settings.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import Combine
import Foundation
import SwiftUI

enum NotchHeightMode: String, PrefValue, CaseIterable, Identifiable {
    case matchRealNotch
    case matchMenuBar
    case custom

    var id: String { rawValue }
    var label: String {
        switch self {
        case .matchRealNotch: "Match physical notch"
        case .matchMenuBar: "Match menu bar"
        case .custom: "Custom"
        }
    }
}

/// How the notch surface is painted.
enum NotchMaterial: String, PrefValue, CaseIterable, Identifiable {
    /// Opaque black. Matches the camera housing exactly; always available.
    case solid
    /// macOS 26 Liquid Glass. Falls back to `solid` on older systems.
    case liquidGlass

    var id: String { rawValue }

    var label: String {
        switch self {
        case .solid: "Solid black"
        case .liquidGlass: "Liquid Glass"
        }
    }

    /// Liquid Glass needs macOS 26. Asking for it on an older system is not an
    /// error — the notch simply stays solid.
    var isAvailable: Bool {
        switch self {
        case .solid: true
        case .liquidGlass:
            if #available(macOS 26.0, *) { true } else { false }
        }
    }
}

/// Which Liquid Glass variant to use.
enum GlassStyle: String, PrefValue, CaseIterable, Identifiable {
    case regular
    case clear

    var id: String { rawValue }

    var label: String {
        switch self {
        case .regular: "Regular"
        case .clear: "Clear"
        }
    }
}

enum OpenTrigger: String, PrefValue, CaseIterable, Identifiable {
    case hover
    case click
    case both

    var id: String { rawValue }
    var label: String {
        switch self {
        case .hover: "Hover"
        case .click: "Click"
        case .both: "Hover or click"
        }
    }

    var allowsHover: Bool { self != .click }
    var allowsClick: Bool { self != .hover }
}

/// Widgets the user can enable, disable and reorder in the expanded notch.
enum WidgetKind: String, CaseIterable, Identifiable, Codable {
    case media
    case shelf
    case calendar
    case mirror
    case timers
    case notes
    case todo
    case shortcuts
    case sessions
    case stats

    var id: String { rawValue }

    var label: String {
        switch self {
        case .media: "Media"
        case .shelf: "Shelf"
        case .calendar: "Calendar"
        case .mirror: "Mirror"
        case .timers: "Timers"
        case .notes: "Notes"
        case .todo: "To-Do"
        case .shortcuts: "Shortcuts"
        case .sessions: "AI Sessions"
        case .stats: "Stats"
        }
    }

    var symbol: String {
        switch self {
        case .media: "play.circle.fill"
        case .shelf: "tray.full.fill"
        case .calendar: "calendar"
        case .mirror: "web.camera.fill"
        case .timers: "timer"
        case .notes: "note.text"
        case .todo: "checklist"
        case .shortcuts: "bolt.fill"
        case .sessions: "brain.head.profile"
        case .stats: "chart.bar.fill"
        }
    }
}

/// Central, observable, locally-persisted application settings.
final class Settings: ObservableObject {
    static let shared = Settings()

    private init() {}

    // MARK: General

    @Pref("general.openTrigger", OpenTrigger.both) var openTrigger: OpenTrigger
    @Pref("general.openDelay", 0.10) var openDelay: Double
    @Pref("general.closeDelay", 0.28) var closeDelay: Double
    @Pref("general.launchAtLogin", false) var launchAtLogin: Bool
    @Pref("general.hapticFeedback", true) var hapticFeedback: Bool
    @Pref("general.animationsEnabled", true) var animationsEnabled: Bool
    @Pref("general.respectReducedMotion", true) var respectReducedMotion: Bool
    @Pref("general.showMenuBarIcon", true) var showMenuBarIcon: Bool
    @Pref("general.closeOnEscape", true) var closeOnEscape: Bool
    @Pref("general.hasCompletedFirstRun", false) var hasCompletedFirstRun: Bool

    // MARK: Appearance

    @Pref("appearance.material", NotchMaterial.solid) var notchMaterial: NotchMaterial
    @Pref("appearance.glassStyle", GlassStyle.regular) var glassStyle: GlassStyle
    /// Dims behind the glass so widget text stays readable over a bright desktop.
    @Pref("appearance.glassDimming", 0.30) var glassDimming: Double
    /// Draw the *collapsed* notch in glass too. Off by default: on a Mac with a
    /// physical notch this puts a translucent smudge over the camera housing.
    @Pref("appearance.glassWhenCollapsed", false) var glassWhenCollapsed: Bool

    /// Whether Liquid Glass should actually be used right now.
    var usesLiquidGlass: Bool {
        notchMaterial == .liquidGlass && notchMaterial.isAvailable
    }

    // MARK: Notch geometry

    @Pref("notch.heightMode", NotchHeightMode.matchRealNotch) var notchHeightMode: NotchHeightMode
    @Pref("notch.customHeight", 32.0) var customNotchHeight: Double
    @Pref("notch.widthAdjustment", 0.0) var notchWidthAdjustment: Double
    @Pref("notch.openWidth", 640.0) var openWidth: Double
    @Pref("notch.openHeight", 190.0) var openHeight: Double
    @Pref("notch.contentPadding", 14.0) var contentPadding: Double
    @Pref("notch.cornerRadius", 22.0) var openCornerRadius: Double
    @Pref("notch.closedCornerRadius", 10.0) var closedCornerRadius: Double
    @Pref("notch.virtualNotchEnabled", true) var virtualNotchEnabled: Bool
    @Pref("notch.virtualNotchHeight", 32.0) var virtualNotchHeight: Double
    @Pref("notch.virtualNotchWidth", 200.0) var virtualNotchWidth: Double
    @Pref("notch.showOnAllDisplays", true) var showOnAllDisplays: Bool
    @Pref("notch.preferredScreenID", String?.none) var preferredScreenID: String?
    @Pref("notch.hideInFullscreen", true) var hideInFullscreen: Bool
    /// Opt-in private-API window placement. See ARCHITECTURE.md § Private APIs.
    @Pref("notch.useElevatedSpace", false) var useElevatedSpace: Bool

    // MARK: Widgets

    @Pref("widgets.enabled", WidgetKind.allCases.map(\.rawValue)) var enabledWidgetIDs: [String]
    @Pref("widgets.order", WidgetKind.allCases.map(\.rawValue)) var widgetOrderIDs: [String]

    /// Enabled widgets in the user's chosen order.
    var orderedWidgets: [WidgetKind] {
        let enabled = Set(enabledWidgetIDs)
        var seen = Set<String>()
        var result = widgetOrderIDs.compactMap { id -> WidgetKind? in
            guard enabled.contains(id), seen.insert(id).inserted else { return nil }
            return WidgetKind(rawValue: id)
        }
        // Any widget added by a newer build that predates the stored order.
        for kind in WidgetKind.allCases where enabled.contains(kind.rawValue) && !seen.contains(kind.rawValue) {
            result.append(kind)
        }
        return result
    }

    func isWidgetEnabled(_ kind: WidgetKind) -> Bool {
        enabledWidgetIDs.contains(kind.rawValue)
    }

    func setWidget(_ kind: WidgetKind, enabled: Bool) {
        var ids = Set(enabledWidgetIDs)
        if enabled { ids.insert(kind.rawValue) } else { ids.remove(kind.rawValue) }
        enabledWidgetIDs = WidgetKind.allCases.map(\.rawValue).filter { ids.contains($0) }
    }

    // MARK: Live activities

    @Pref("activity.media", true) var activityMedia: Bool
    @Pref("activity.battery", true) var activityBattery: Bool
    @Pref("activity.charging", true) var activityCharging: Bool
    @Pref("activity.bluetooth", true) var activityBluetooth: Bool
    @Pref("activity.timer", true) var activityTimer: Bool
    @Pref("activity.sessions", true) var activitySessions: Bool
    @Pref("activity.duration", 2.6) var activityDuration: Double

    // MARK: HUD  (off by default — see spec Phase 11)

    @Pref("hud.volume", false) var hudVolume: Bool
    @Pref("hud.brightness", false) var hudBrightness: Bool
    @Pref("hud.keyboardBrightness", false) var hudKeyboardBrightness: Bool

    // MARK: Media

    @Pref("media.showArtwork", true) var mediaShowArtwork: Bool
    @Pref("media.tintFromArtwork", true) var mediaTintFromArtwork: Bool
    @Pref("media.pollInterval", 1.0) var mediaPollInterval: Double

    // MARK: Shelf

    @Pref("shelf.persistBetweenLaunches", true) var shelfPersist: Bool
    @Pref("shelf.autoExpandOnDrag", true) var shelfAutoExpandOnDrag: Bool

    // MARK: Calendar

    @Pref("calendar.enabledCalendarIDs", [String]()) var enabledCalendarIDs: [String]
    @Pref("calendar.showAllCalendars", true) var calendarShowAll: Bool

    // MARK: Mirror

    @Pref("mirror.deviceID", String?.none) var mirrorDeviceID: String?
    @Pref("mirror.flipHorizontally", true) var mirrorFlipHorizontally: Bool

    // MARK: Shortcuts

    @Pref("shortcuts.pinned", [String]()) var pinnedShortcutNames: [String]

    // MARK: Sessions (Claude Code / Codex monitoring)

    @Pref("sessions.watchClaudeCode", true) var watchClaudeCode: Bool
    @Pref("sessions.watchCodex", true) var watchCodex: Bool
    @Pref("sessions.notifyOnIdle", true) var sessionsNotifyOnIdle: Bool

    // MARK: Bindings

    /// Two-way SwiftUI binding for any settings key path.
    func binding<Value>(_ keyPath: ReferenceWritableKeyPath<Settings, Value>) -> Binding<Value> {
        Binding(
            get: { self[keyPath: keyPath] },
            set: { self[keyPath: keyPath] = $0 }
        )
    }
}
