//
//  PrivacySettingsView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import SwiftUI

struct PrivacySettingsView: View {
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(
                title: "Permissions",
                footer: "LocalNook asks for each of these only when you first use the feature that needs it. Declining one disables just that feature — everything else keeps working."
            ) {
                ForEach(PermissionKind.allCases) { kind in
                    row(kind)
                    if kind != PermissionKind.allCases.last {
                        Divider().opacity(0.4)
                    }
                }
            }

            SettingsSection(title: "Data on this Mac") {
                LabeledContent("Settings") {
                    Text("~/Library/Preferences").foregroundStyle(.secondary)
                }
                LabeledContent("Shelf, notes, to-dos") {
                    Text("~/Library/Application Support/LocalNook").foregroundStyle(.secondary)
                }
                Button("Reveal data folder in Finder") {
                    NSWorkspace.shared.selectFile(
                        nil, inFileViewerRootedAtPath: AppInfo.supportDirectory.path
                    )
                }
            }

            Button("Re-check permissions") { permissions.refreshAll() }
        }
        .onAppear { permissions.refreshAll() }
    }

    private func row(_ kind: PermissionKind) -> some View {
        let state = permissions.states[kind] ?? .unknown
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.symbol)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.system(size: 13, weight: .medium))
                Text(kind.usedFor)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Label(state.label, systemImage: state.symbol)
                .font(.system(size: 11))
                .foregroundStyle(state.tint)
                .labelStyle(.titleAndIcon)
            Button("Open") { permissions.open(kind) }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}
