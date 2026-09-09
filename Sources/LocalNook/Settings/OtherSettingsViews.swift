//
//  OtherSettingsViews.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import AppKit
import SwiftUI

// MARK: - Widgets

struct WidgetSettingsView: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(
                title: "Dashboard",
                footer: "Pinned widgets appear side by side when the notch opens, in this order. Anything you unpin still works — it moves to Tools. If the panel is too narrow for everything pinned, the ones at the end move into the “More” control at the right of the dashboard, which takes you to them rather than hiding them."
            ) {
                ForEach(WidgetKind.allCases.filter(\.suitsDashboard)) { kind in
                    HStack(spacing: 10) {
                        Image(systemName: kind.symbol)
                            .frame(width: 20)
                            .foregroundStyle(.secondary)
                        Toggle(kind.label, isOn: Binding(
                            get: { settings.dashboardWidgetIDs.contains(kind.rawValue) },
                            set: { settings.setDashboardWidget(kind, on: $0) }
                        ))
                        .disabled(!settings.isWidgetEnabled(kind))
                        Spacer()
                        if !settings.isWidgetEnabled(kind) {
                            Text("disabled below")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        } else {
                            Button { moveDashboard(kind, by: -1) } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.borderless)
                            .disabled(dashboardIndex(kind) <= 0)
                            Button { moveDashboard(kind, by: 1) } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.borderless)
                            .disabled(dashboardIndex(kind) < 0
                                      || dashboardIndex(kind) >= settings.dashboardWidgetIDs.count - 1)
                        }
                    }
                }
            }

            SettingsSection(
                title: "AI session labels",
                footer: "Session files live on this Mac and nothing here is ever sent anywhere. This choice is separate from switching the AI Sessions widget on: the widget works either way."
            ) {
                Picker("Labels", selection: Binding(
                    get: { settings.sessionLabelDepth },
                    set: { settings.sessionLabelDepth = $0 }
                )) {
                    ForEach(SessionLabelDepth.allCases) { depth in
                        Text(depth.label).tag(depth)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(settings.sessionLabelDepth.explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection(
                title: "Available widgets",
                footer: "Drag to reorder. The order here is the order of the rail inside the expanded notch."
            ) {
                ForEach(settings.widgetOrderIDs, id: \.self) { id in
                    if let kind = WidgetKind(rawValue: id) {
                        widgetRow(kind)
                    }
                }
            }

            WidgetDetailSettingsView()
        }
    }

    private func widgetRow(_ kind: WidgetKind) -> some View {
        HStack(spacing: 10) {
            Image(systemName: kind.symbol)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Toggle(kind.label, isOn: Binding(
                get: { settings.isWidgetEnabled(kind) },
                set: { settings.setWidget(kind, enabled: $0) }
            ))
            Spacer()
            Button { move(kind, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(index(of: kind) == 0)
            Button { move(kind, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(index(of: kind) == settings.widgetOrderIDs.count - 1)
        }
    }

    private func dashboardIndex(_ kind: WidgetKind) -> Int {
        settings.dashboardWidgetIDs.firstIndex(of: kind.rawValue) ?? -1
    }

    private func moveDashboard(_ kind: WidgetKind, by offset: Int) {
        var order = settings.dashboardWidgetIDs
        guard let from = order.firstIndex(of: kind.rawValue) else { return }
        let to = from + offset
        guard order.indices.contains(to) else { return }
        order.swapAt(from, to)
        settings.dashboardWidgetIDs = order
    }

    private func index(of kind: WidgetKind) -> Int {
        settings.widgetOrderIDs.firstIndex(of: kind.rawValue) ?? 0
    }

    private func move(_ kind: WidgetKind, by offset: Int) {
        var order = settings.widgetOrderIDs
        guard let from = order.firstIndex(of: kind.rawValue) else { return }
        let to = from + offset
        guard order.indices.contains(to) else { return }
        order.swapAt(from, to)
        settings.widgetOrderIDs = order
    }
}

// MARK: - Live activities

struct ActivitySettingsView: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(
                title: "Show beside the closed notch",
                footer: "Live activities appear briefly next to the notch and then fade out, without expanding it."
            ) {
                Toggle("Media playback", isOn: settings.binding(\.activityMedia))
                Toggle("Battery level", isOn: settings.binding(\.activityBattery))
                Toggle("Charging connected / disconnected", isOn: settings.binding(\.activityCharging))
                Toggle("Bluetooth device connected / disconnected", isOn: settings.binding(\.activityBluetooth))
                Toggle("Timers", isOn: settings.binding(\.activityTimer))
                Toggle("AI coding sessions", isOn: settings.binding(\.activitySessions))
            }
            SettingsSection(title: "Timing") {
                SettingsSlider(
                    title: "On-screen duration", value: settings.binding(\.activityDuration),
                    range: 1...8, step: 0.2, unit: " s", format: "%.1f"
                )
            }
        }
    }
}

// MARK: - HUD

struct HUDSettingsView: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(
                title: "Replace system HUDs",
                footer: "Off by default. LocalNook reads volume and brightness through public APIs and shows its own indicator near the notch. It does not suppress the built-in macOS HUD, so you may briefly see both."
            ) {
                Toggle("Volume", isOn: settings.binding(\.hudVolume))
                Text("Display and keyboard brightness HUDs are not implemented.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - About

struct AboutSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "LocalNook") {
                Text("Version \(AppInfo.version) (\(AppInfo.build))")
                Text("Commit: \(AppInfo.commit)").font(.caption).textSelection(.enabled)
                Text("Built: \(AppInfo.builtAt)").font(.caption)
                Text("A local-first notch utility for macOS.")
                    .foregroundStyle(.secondary)
            }
            SettingsSection(
                title: "Licence",
                footer: "LocalNook is free software under the GNU General Public License v3.0 or later, because it is derived from boring.notch. You may study, modify and redistribute it under the same terms."
            ) {
                Text("GNU General Public License v3.0 or later")
                Text("Derived from boring.notch © The Boring Team")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open LICENSE") { AppInfo.revealDocument("LICENSE") }
                    Button("Third-party licences") { AppInfo.revealDocument("THIRD_PARTY_LICENSES.md") }
                }
            }
            SettingsSection(
                title: "Privacy",
                footer: "LocalNook makes no network requests during normal operation. There is no account, licence check, update check, telemetry or analytics."
            ) {
                Label("No network access", systemImage: "wifi.slash")
                Label("No account or licence server", systemImage: "person.crop.circle.badge.xmark")
                Label("All data stored on this Mac", systemImage: "internaldrive")
            }
        }
    }
}

enum AppInfo {
    // These are immutable and derived from the command line, so they are safe
    // to read from any actor — and must be, because the media providers run off
    // the main actor and still need to know which defaults store to use.
    nonisolated static let isSelfTest = CommandLine.arguments.contains("--self-test")
    /// Offscreen PNG rendering. Writes images to disk automatically, so it must
    /// never render anything read out of a transcript.
    static let isPreviewRender = CommandLine.arguments.contains("--render-preview")
    /// Contexts in which transcript content must not be read at all.
    static var forbidsTranscriptReads: Bool { isSelfTest || isPreviewRender }
    static let testDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LocalNook-tests-\(UUID().uuidString)", isDirectory: true)
    nonisolated static let testSuiteName = "com.localnook.tests.\(UUID().uuidString)"
    // UserDefaults is thread-safe but not Sendable, so the annotation is the
    // honest form: shared, immutable reference, safe to use from any actor.
    nonisolated(unsafe) static let defaults: UserDefaults = isSelfTest
        ? UserDefaults(suiteName: testSuiteName)! : .standard

    /// Whether the process is running from a real `.app` bundle.
    ///
    /// Several system APIs — `UNUserNotificationCenter.current()` most sharply —
    /// raise an uncaught Objective-C exception when there is no bundle proxy,
    /// which happens when the bare executable is run straight from the build
    /// directory. Guarding on this keeps `swift run` and the preview renderer
    /// from taking the whole process down.
    static var isRunningFromBundle: Bool {
        Bundle.main.bundleIdentifier != nil
            && Bundle.main.bundleURL.pathExtension == "app"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var commit: String { Bundle.main.object(forInfoDictionaryKey: "LocalNookCommit") as? String ?? "unpackaged" }
    static var builtAt: String { Bundle.main.object(forInfoDictionaryKey: "LocalNookBuiltAt") as? String ?? "unpackaged" }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// Documents ship inside the bundle's Resources so they are always at hand.
    static func revealDocument(_ name: String) {
        if let url = Bundle.main.url(forResource: name, withExtension: nil) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Where LocalNook keeps its own files (shelf items, notes, to-dos).
    static var supportDirectory: URL {
        let base = isSelfTest ? testDirectory : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LocalNook", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Per-widget settings

/// Settings that belong to individual widgets, shown under the Widgets tab.
struct WidgetDetailSettingsView: View {
    @EnvironmentObject var settings: Settings
    @ObservedObject private var calendar = CalendarManager.shared
    @LNState private var confirmingClearShelf = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(
                title: "Media",
                footer: "LocalNook reads playback over Apple Events, which reaches apps that publish a scripting dictionary — Music, Spotify, and browser tabs. There is no system-wide Now Playing feed available to an ordinary app, so a source that publishes no dictionary is not visible. See ARCHITECTURE.md."
            ) {
                Toggle("Show album artwork", isOn: settings.binding(\.mediaShowArtwork))
                SettingsSlider(
                    title: "Refresh while playing", value: settings.binding(\.mediaPollInterval),
                    range: 0.5...5, step: 0.5, unit: " s", format: "%.1f"
                )
            }

            SettingsSection(
                title: "Browser media",
                footer: "Off by default because reading tabs needs Automation permission for that browser. LocalNook checks whether it already has that permission without asking for it, so nothing here can raise a dialog on its own — pressing Connect is what asks. That press is also what puts LocalNook into System Settings ▸ Privacy & Security ▸ Automation: that list only shows apps that have asked, so until you press it there is nothing there to find. Nothing is read until you switch this on, and nothing leaves this Mac."
            ) {
                Toggle("Show what a browser is playing",
                       isOn: settings.binding(\.browserMediaEnabled))
                Text("Chrome and Safari. LocalNook reads the title of a tab on a "
                     + "known player — YouTube, YouTube Music, Spotify Web, "
                     + "SoundCloud, Twitch, Vimeo, Bandcamp — and asks macOS "
                     + "whether the browser is emitting audio.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("That says the browser is making a noise, not which tab is "
                     + "making it: neither browser publishes a per-tab audio "
                     + "property, and Chrome mixes every tab through one shared "
                     + "audio process. So playback shows as “Browser audio "
                     + "active” rather than “Playing”, unless page access is on.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("For a real playing/paused state, a scrubber and a working "
                     + "play/pause button, also turn on “Allow JavaScript from "
                     + "Apple Events” in your browser (Chrome: View ▸ Developer. "
                     + "Safari: Develop menu). It lets any scripting app run "
                     + "JavaScript in every tab, so it is your call, and "
                     + "LocalNook cannot and does not set it for you.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.browserMediaEnabled {
                    BrowserConnectionRows()
                }
            }

            SettingsSection(title: "Shelf") {
                Toggle("Keep items between launches", isOn: settings.binding(\.shelfPersist))
                Toggle("Open the shelf when a drag arrives", isOn: settings.binding(\.shelfAutoExpandOnDrag))
                HStack {
                    Text("\(ShelfStore.shared.items.count) item(s) on the shelf")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear shelf…", role: .destructive) { confirmingClearShelf = true }
                        .confirmationDialog(
                            "Clear the shelf?",
                            isPresented: $confirmingClearShelf,
                            titleVisibility: .visible
                        ) {
                            Button("Clear \(ShelfStore.shared.items.count) item(s)",
                                   role: .destructive) {
                                ShelfStore.shared.requestClear()
                                ShelfStore.shared.confirmClear()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            // Worth saying plainly: references to your own files
                            // are only forgotten, but anything LocalNook created
                            // for you — a dragged snippet of text, say — is
                            // deleted from disk and cannot be recovered.
                            Text("Your own files stay where they are. Notes and "
                                 + "snippets LocalNook saved for you are deleted.")
                        }
                }
            }

            SettingsSection(
                title: "Calendar",
                footer: calendar.hasAccess ? nil : "Calendar access has not been granted yet. Open the Calendar widget once to be asked."
            ) {
                Toggle("Show every calendar", isOn: settings.binding(\.calendarShowAll))
                if !settings.calendarShowAll {
                    ForEach(calendar.availableCalendars, id: \.calendarIdentifier) { item in
                        Toggle(item.title, isOn: Binding(
                            get: { settings.enabledCalendarIDs.contains(item.calendarIdentifier) },
                            set: { on in
                                var ids = Set(settings.enabledCalendarIDs)
                                if on { ids.insert(item.calendarIdentifier) }
                                else { ids.remove(item.calendarIdentifier) }
                                settings.enabledCalendarIDs = Array(ids)
                                calendar.reload()
                            }
                        ))
                    }
                }
            }

            SettingsSection(
                title: "AI coding sessions",
                footer: "LocalNook watches the transcript folders for Claude Code (~/.claude/projects) and Codex (~/.codex/sessions). It reads file timestamps only — it never opens a transcript or reads any conversation."
            ) {
                Toggle("Watch Claude Code", isOn: settings.binding(\.watchClaudeCode))
                Toggle("Watch Codex", isOn: settings.binding(\.watchCodex))
                Toggle("Tell me when a session goes quiet", isOn: settings.binding(\.sessionsNotifyOnIdle))
                Button("Rescan now") { SessionMonitor.shared.restart() }
            }
        }
    }
}


/// Per-browser Automation consent, read and requested where it can be acted on.
///
/// The state shown here is read with `AEDeterminePermissionToAutomateTarget`,
/// which answers from the system's own records without sending an Apple Event,
/// so simply opening this pane asks the user for nothing. Pressing Connect is
/// the deliberate request — and the only thing that puts LocalNook into System
/// Settings ▸ Privacy & Security ▸ Automation, which lists apps that have
/// asked. Until something asks, there is no switch there to find.
private struct BrowserConnectionRows: View {
    @ObservedObject private var media = MediaManager.shared
    @LNState private var refreshed = Date()

    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(MediaBrowser.allCases) { browser in
                row(for: browser)
            }
        }
        .padding(.top, 2)
        .onReceive(ticker) { refreshed = $0 }
    }

    private func row(for browser: MediaBrowser) -> some View {
        let installed = MediaScriptBridge.isInstalled(bundleID: browser.bundleID)
        let running = MediaScriptBridge.isRunning(bundleID: browser.bundleID)
        let status = AutomationPermission.status(forBundleID: browser.bundleID)
        return HStack(spacing: 8) {
            Image(systemName: status.isGranted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(status.isGranted ? Color.green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(browser.displayName).font(.system(size: 12, weight: .medium))
                Text(detail(installed: installed, running: running, status: status))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if installed, running, !status.isGranted {
                if status == .denied {
                    Button("Open Settings") { Permissions.shared.open(.automation) }
                } else {
                    Button("Connect") { media.connect(browser) }
                }
            }
        }
        .id(refreshed)
    }

    private func detail(
        installed: Bool, running: Bool, status: AutomationPermission.Status
    ) -> String {
        guard installed else { return "Not installed" }
        guard running else { return "Not running — open it to connect" }
        switch status {
        case .granted: return "Connected"
        case .denied: return "Refused — re-enable under Automation ▸ LocalNook"
        case .notDetermined: return "Not requested yet"
        case .targetNotRunning: return "Not running — open it to connect"
        case .other(let code): return "Unexpected status \(code)"
        }
    }
}
