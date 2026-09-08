//
//  SettingsView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, notch, widgets, activities, hud, privacy, about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: "General"
        case .notch: "Notch"
        case .widgets: "Widgets"
        case .activities: "Live Activities"
        case .hud: "HUD"
        case .privacy: "Privacy"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .notch: "rectangle.topthird.inset.filled"
        case .widgets: "square.grid.2x2"
        case .activities: "bolt.badge.clock"
        case .hud: "slider.horizontal.3"
        case .privacy: "hand.raised"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    @LNState private var tab: SettingsTab = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $tab) { item in
                Label(item.label, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            ScrollView {
                content
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(tab.label)
        }
        .frame(minWidth: 720, minHeight: 540)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general: GeneralSettingsView()
        case .notch: NotchSettingsView()
        case .widgets: WidgetSettingsView()
        case .activities: ActivitySettingsView()
        case .hud: HUDSettingsView()
        case .privacy: PrivacySettingsView()
        case .about: AboutSettingsView()
        }
    }
}

// MARK: - Shared layout

/// A titled group of settings rows.
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                }
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 18)
    }
}

/// A labelled slider that shows its current value.
struct SettingsSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit: String = ""
    var format: String = "%.0f"

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value) + unit)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}
