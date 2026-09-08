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
                title: "Available widgets",
                footer: "Drag to reorder. The order here is the order of the rail inside the expanded notch."
            ) {
                ForEach(settings.widgetOrderIDs, id: \.self) { id in
                    if let kind = WidgetKind(rawValue: id) {
                        widgetRow(kind)
                    }
                }
            }
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
                Toggle("Display brightness", isOn: settings.binding(\.hudBrightness))
                Toggle("Keyboard brightness", isOn: settings.binding(\.hudKeyboardBrightness))
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
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LocalNook", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
