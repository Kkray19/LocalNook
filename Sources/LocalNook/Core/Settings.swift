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

    /// Opacity of the Liquid Glass panel when the notch is **expanded**.
    ///
    /// Separate from `glassDimming`, which is the dark scrim *behind* the
    /// glass and exists to keep widget text readable over a bright desktop.
    /// This is the whole surface — scrim, glass and hairline together — so
    /// lowering it lets more of the desktop through rather than making the
    /// panel darker. 1.0 by default: the same panel as before unless asked
    /// otherwise.
    static let defaultGlassOpacity = 1.0
    @Pref("appearance.glassOpacity", Settings.defaultGlassOpacity) var glassOpacity: Double

    /// Opacity of the solid material when the notch is **expanded**.
    ///
    /// Applies to the expanded panel only, never to the collapsed notch. A
    /// collapsed notch sits over the physical camera housing on a notched Mac
    /// and has to match it exactly; letting the desktop show through there
    /// would draw a translucent rectangle around the housing, which is the one
    /// thing the surface must never do.
    static let defaultExpandedOpacity = 1.0
    @Pref("appearance.expandedOpacity", Settings.defaultExpandedOpacity) var expandedOpacity: Double

    /// Whether Liquid Glass should actually be used right now.
    var usesLiquidGlass: Bool {
        notchMaterial == .liquidGlass && notchMaterial.isAvailable
    }

    // MARK: Notch geometry

    @Pref("notch.heightMode", NotchHeightMode.matchRealNotch) var notchHeightMode: NotchHeightMode
    @Pref("notch.customHeight", 32.0) var customNotchHeight: Double
    @Pref("notch.widthAdjustment", 0.0) var notchWidthAdjustment: Double
    @Pref("notch.openWidth", 720.0) var openWidth: Double
    @Pref("notch.openHeight", 168.0) var openHeight: Double
    @Pref("notch.contentPadding", 14.0) var contentPadding: Double
    @Pref("notch.cornerRadius", 22.0) var openCornerRadius: Double
    @Pref("notch.closedCornerRadius", 10.0) var closedCornerRadius: Double
    @Pref("notch.virtualNotchEnabled", true) var virtualNotchEnabled: Bool
    @Pref("notch.virtualNotchHeight", 32.0) var virtualNotchHeight: Double
    @Pref("notch.virtualNotchWidth", 200.0) var virtualNotchWidth: Double
    @Pref("notch.showOnAllDisplays", true) var showOnAllDisplays: Bool
    @Pref("notch.preferredScreenID", String?.none) var preferredScreenID: String?
    @Pref("notch.hideInFullscreen", true) var hideInFullscreen: Bool

    /// Extra height on the invisible catcher that opens the notch on hover.
    ///
    /// The catcher is otherwise exactly the size of the visible notch, which
    /// makes it accurate and slightly unforgiving: a pointer thrown at the top
    /// of the screen can arrive a couple of points below the target and glance
    /// off it. This adds a margin *below* the notch only — never wider, because
    /// width is what would start eating clicks meant for the menu bar.
    @Pref("notch.hoverPadding", 3.0) var hoverPadding: Double
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

    /// Widgets shown side by side on the Dashboard, in order.
    // MARK: Media

    /// Whether LocalNook may read what a browser is playing.
    ///
    /// Off by default and deliberately so: reading tabs needs Automation
    /// consent for that browser, and macOS prompts on first use. Opening the
    /// dashboard must never be the reason a permission dialog appears, so this
    /// is an explicit choice made in Settings.
    @Pref("media.browserEnabled", false) var browserMediaEnabled: Bool

    // MARK: Sessions

    /// How much of a transcript the sessions widget may read.
    ///
    /// Deliberately defaults to metadata only. Enabling the sessions widget is
    /// not consent to read inside transcript files; that is a separate,
    /// explicit choice, and an existing choice is never overwritten because
    /// this is stored under its own key. See SessionDetail.
    /// Exposed so a test can assert the shipped default without reading the
    /// user's stored choice, which may legitimately differ.
    static let defaultSessionLabelDepth = SessionLabelDepth.metadataOnly.rawValue

    @Pref("sessions.labelDepth", Settings.defaultSessionLabelDepth)
    var sessionLabelDepthID: String

    var sessionLabelDepth: SessionLabelDepth {
        get { SessionLabelDepth(rawValue: sessionLabelDepthID) ?? .metadataOnly }
        set { sessionLabelDepthID = newValue.rawValue }
    }

    @Pref("widgets.dashboard", ["media", "calendar", "timers"]) var dashboardWidgetIDs: [String]

    /// Dashboard widgets that are both chosen *and* enabled.
    ///
    /// A widget switched off in Settings is dropped rather than replaced — a
    /// silent fallback would put back something the user deliberately removed.
    var dashboardWidgets: [WidgetKind] {
        let enabled = Set(enabledWidgetIDs)
        var seen = Set<String>()
        return dashboardWidgetIDs.compactMap { id in
            guard enabled.contains(id), seen.insert(id).inserted,
                  let kind = WidgetKind(rawValue: id), kind.suitsDashboard
            else { return nil }
            return kind
        }
    }

    func setDashboardWidget(_ kind: WidgetKind, on: Bool) {
        var ids = dashboardWidgetIDs.filter { $0 != kind.rawValue }
        if on { ids.append(kind.rawValue) }
        dashboardWidgetIDs = ids
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


    // MARK: Shortcuts

    @Pref("shortcuts.pinned", [String]()) var pinnedShortcutNames: [String]

    // MARK: Gestures

    /// Two-finger swipe over the notch to open and close it.
    @Pref("gestures.swipeToToggle", true) var swipeToToggle: Bool
    /// Flips which finger direction opens, for anyone to whom the default
    /// feels backwards. The gesture already follows natural-scrolling; this is
    /// a preference on top of that, not a correction for it.
    @Pref("gestures.swipeInverted", false) var swipeInverted: Bool

    // MARK: Sessions (Claude Code / Codex monitoring)

    @Pref("sessions.watchClaudeCode", true) var watchClaudeCode: Bool
    @Pref("sessions.watchCodex", true) var watchCodex: Bool
    /// The ChatGPT desktop app's local chat list. Timestamps only unless session
    /// labels are on, in which case chat titles too. See ChatGPTCatalogReader.
    @Pref("sessions.watchChatGPT", true) var watchChatGPT: Bool
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
