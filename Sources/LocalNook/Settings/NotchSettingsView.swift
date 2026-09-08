//
//  NotchSettingsView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import AppKit
import SwiftUI

struct NotchSettingsView: View {
    @EnvironmentObject var settings: Settings

    private var screens: [NSScreen] { NSScreen.screens }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Closed size") {
                Picker("Height", selection: settings.binding(\.notchHeightMode)) {
                    ForEach(NotchHeightMode.allCases) { Text($0.label).tag($0) }
                }
                if settings.notchHeightMode == .custom {
                    SettingsSlider(
                        title: "Custom height", value: settings.binding(\.customNotchHeight),
                        range: 16...60, step: 1, unit: " pt"
                    )
                }
                SettingsSlider(
                    title: "Width adjustment", value: settings.binding(\.notchWidthAdjustment),
                    range: -40...120, step: 1, unit: " pt", format: "%+.0f"
                )
                SettingsSlider(
                    title: "Closed corner radius", value: settings.binding(\.closedCornerRadius),
                    range: 0...24, step: 1, unit: " pt"
                )
            }

            SettingsSection(title: "Expanded size") {
                SettingsSlider(
                    title: "Width", value: settings.binding(\.openWidth),
                    range: 380...1000, step: 10, unit: " pt"
                )
                SettingsSlider(
                    title: "Height", value: settings.binding(\.openHeight),
                    range: 130...420, step: 5, unit: " pt"
                )
                SettingsSlider(
                    title: "Corner radius", value: settings.binding(\.openCornerRadius),
                    range: 8...40, step: 1, unit: " pt"
                )
                SettingsSlider(
                    title: "Content padding", value: settings.binding(\.contentPadding),
                    range: 4...32, step: 1, unit: " pt"
                )
            }

            SettingsSection(
                title: "Displays",
                footer: displayFooter
            ) {
                Toggle("Show on every display", isOn: settings.binding(\.showOnAllDisplays))
                if !settings.showOnAllDisplays {
                    Picker("Preferred display", selection: Binding(
                        get: { settings.preferredScreenID ?? "" },
                        set: { settings.preferredScreenID = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Automatic (main display)").tag("")
                        ForEach(screens, id: \.stableID) { screen in
                            if let id = screen.stableID {
                                Text(describe(screen)).tag(id)
                            }
                        }
                    }
                }
                Toggle("Hide while an app is full screen", isOn: settings.binding(\.hideInFullscreen))
            }

            SettingsSection(
                title: "Virtual notch",
                footer: "Displays without a physical camera housing get a drawn notch instead, so external monitors behave the same way."
            ) {
                Toggle("Show a virtual notch on displays without one",
                       isOn: settings.binding(\.virtualNotchEnabled))
                if settings.virtualNotchEnabled {
                    SettingsSlider(
                        title: "Virtual width", value: settings.binding(\.virtualNotchWidth),
                        range: 120...420, step: 5, unit: " pt"
                    )
                    SettingsSlider(
                        title: "Virtual height", value: settings.binding(\.virtualNotchHeight),
                        range: 16...60, step: 1, unit: " pt"
                    )
                }
            }

            SettingsSection(
                title: "Advanced",
                footer: "Uses undocumented CoreGraphics window-space calls to float above full-screen apps. Off by default. If a future macOS removes those calls, LocalNook falls back to a normal window level automatically."
            ) {
                Toggle("Float above full-screen apps (private API)",
                       isOn: settings.binding(\.useElevatedSpace))
            }

            Button("Reset notch geometry to defaults", role: .destructive, action: resetGeometry)
                .padding(.top, 4)
        }
        .onChange(of: geometrySignature) { _, _ in
            NotificationCenter.default.post(name: .notchGeometryChanged, object: nil)
        }
    }

    /// One value that changes whenever any geometry-affecting setting changes,
    /// so a single `onChange` can trigger the panel rebuild.
    private var geometrySignature: String {
        [
            settings.notchHeightMode.rawValue,
            "\(settings.customNotchHeight)", "\(settings.notchWidthAdjustment)",
            "\(settings.openWidth)", "\(settings.openHeight)",
            "\(settings.virtualNotchEnabled)", "\(settings.virtualNotchWidth)",
            "\(settings.virtualNotchHeight)", "\(settings.showOnAllDisplays)",
            settings.preferredScreenID ?? "", "\(settings.useElevatedSpace)",
        ].joined(separator: "|")
    }

    private var displayFooter: String {
        let notched = screens.filter(\.hasPhysicalNotch).count
        return "\(screens.count) display(s) connected, \(notched) with a physical notch."
    }

    private func describe(_ screen: NSScreen) -> String {
        let size = "\(Int(screen.frame.width))×\(Int(screen.frame.height))"
        return screen.hasPhysicalNotch
            ? "\(screen.localizedName) — \(size), notched"
            : "\(screen.localizedName) — \(size)"
    }

    private func resetGeometry() {
        settings.notchHeightMode = .matchRealNotch
        settings.customNotchHeight = 32
        settings.notchWidthAdjustment = 0
        settings.openWidth = 640
        settings.openHeight = 190
        settings.openCornerRadius = 22
        settings.closedCornerRadius = 10
        settings.contentPadding = 14
        NotificationCenter.default.post(name: .notchGeometryChanged, object: nil)
    }
}
