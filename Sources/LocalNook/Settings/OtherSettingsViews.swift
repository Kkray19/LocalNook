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
                footer: "These appear side by side when the notch opens. If the panel is too narrow for all of them, the ones at the end are left out rather than everything being shrunk."
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
    static let isSelfTest = CommandLine.arguments.contains("--self-test")
    static let testDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LocalNook-tests-\(UUID().uuidString)", isDirectory: true)
    static let testSuiteName = "com.localnook.tests.\(UUID().uuidString)"
    static let defaults: UserDefaults = isSelfTest
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(
                title: "Media",
                footer: "LocalNook reads playback over Apple Events, which reaches apps with a scripting dictionary — Music and Spotify. Browser tabs and other Now Playing sources are not visible this way. See ARCHITECTURE.md for why."
            ) {
                Toggle("Show album artwork", isOn: settings.binding(\.mediaShowArtwork))
                SettingsSlider(
                    title: "Refresh while playing", value: settings.binding(\.mediaPollInterval),
                    range: 0.5...5, step: 0.5, unit: " s", format: "%.1f"
                )
            }

            SettingsSection(title: "Shelf") {
                Toggle("Keep items between launches", isOn: settings.binding(\.shelfPersist))
                Toggle("Open the shelf when a drag arrives", isOn: settings.binding(\.shelfAutoExpandOnDrag))
                HStack {
                    Text("\(ShelfStore.shared.items.count) item(s) on the shelf")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear shelf", role: .destructive) { ShelfStore.shared.clearAll() }
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

            SettingsSection(title: "Mirror") {
                Toggle("Flip horizontally (mirror image)", isOn: settings.binding(\.mirrorFlipHorizontally))
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
