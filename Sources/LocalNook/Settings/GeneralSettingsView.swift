//
//  GeneralSettingsView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var settings: Settings
    @LNState private var loginItemError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Startup") {
                Toggle("Launch LocalNook at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let loginItemError {
                    Text(loginItemError)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                Toggle("Show menu bar icon", isOn: settings.binding(\.showMenuBarIcon))
            }

            SettingsSection(
                title: "Opening & closing",
                footer: "The open delay stops the notch from expanding as the pointer merely passes over it. The close delay keeps it open while you move toward a control."
            ) {
                Picker("Open with", selection: settings.binding(\.openTrigger)) {
                    ForEach(OpenTrigger.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                SettingsSlider(
                    title: "Open delay", value: settings.binding(\.openDelay),
                    range: 0...1.0, step: 0.02, unit: " s", format: "%.2f"
                )
                SettingsSlider(
                    title: "Close delay", value: settings.binding(\.closeDelay),
                    range: 0...2.0, step: 0.02, unit: " s", format: "%.2f"
                )
                Toggle("Collapse when Escape is pressed", isOn: settings.binding(\.closeOnEscape))
            }

            SettingsSection(
                title: "Feedback & motion",
                footer: "With “Respect Reduce Motion” on, LocalNook follows the system setting in Accessibility ▸ Display and switches to instant transitions."
            ) {
                Toggle("Haptic feedback when opening", isOn: settings.binding(\.hapticFeedback))
                Toggle("Animate transitions", isOn: settings.binding(\.animationsEnabled))
                Toggle("Respect Reduce Motion", isOn: settings.binding(\.respectReducedMotion))
                    .disabled(!settings.animationsEnabled)
            }
        }
        .onAppear { syncLaunchAtLoginFromSystem() }
    }

    /// `SMAppService` is the modern, sandbox-safe login item API — no helper
    /// bundle and no third-party dependency required.
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            settings.launchAtLogin = enabled
            loginItemError = nil
        } catch {
            // Most commonly: the app is being run from the build directory
            // rather than /Applications, which LaunchServices refuses.
            loginItemError = "Could not update the login item: \(error.localizedDescription)"
            settings.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    /// The user can remove the login item in System Settings; re-read the truth.
    private func syncLaunchAtLoginFromSystem() {
        let isEnabled = SMAppService.mainApp.status == .enabled
        if isEnabled != settings.launchAtLogin {
            settings.launchAtLogin = isEnabled
        }
    }
}
