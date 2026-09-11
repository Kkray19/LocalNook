//
//  AppsWidgetView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import SwiftUI

/// Full-size Quick Apps: a wrapping grid of pinned apps, each opening on click,
/// with an add tile and remove-on-hover.
struct AppsWidgetView: View {
    @ObservedObject private var launcher = AppLauncher.shared

    private let columns = [GridItem(.adaptive(minimum: 56, maximum: 72), spacing: 8)]

    var body: some View {
        let apps = launcher.pinned
        if apps.isEmpty {
            CompactMessage(
                symbol: "square.grid.2x2",
                title: "No pinned apps",
                detail: "Pin the apps you open most and launch them from the notch.",
                actionTitle: "Pin an app"
            ) { launcher.promptToPin() }
        } else {
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(apps) { app in
                        AppTile(app: app, removable: true)
                    }
                    if launcher.canPinMore { AddTile() }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// One launchable app: icon, name, and a remove badge on hover.
struct AppTile: View {
    let app: PinnedApp
    var removable = false

    @ObservedObject private var launcher = AppLauncher.shared
    @LNState private var isHovering = false

    var body: some View {
        Button { launcher.launch(app) } label: {
            VStack(spacing: 4) {
                Image(nsImage: launcher.icon(for: app))
                    .resizable()
                    .frame(width: 34, height: 34)
                Text(app.name)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isHovering ? Theme.secondaryText : Theme.tertiaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(isHovering ? Theme.surfaceHover : Theme.surface)
            }
            .overlay(alignment: .topTrailing) {
                if removable, isHovering {
                    Button { launcher.unpin(app.bundleID) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white, .black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: -4)
                    .help("Unpin \(app.name)")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(NotchMotion.quick) { isHovering = hovering } }
        .help("Open \(app.name)")
    }
}

/// The tile that pins a new app.
struct AddTile: View {
    @ObservedObject private var launcher = AppLauncher.shared
    @LNState private var isHovering = false

    var body: some View {
        Button { launcher.promptToPin() } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isHovering ? Theme.secondaryText : Theme.tertiaryText)
                    .frame(width: 34, height: 34)
                Text("Add")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.divider, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(NotchMotion.quick) { isHovering = hovering } }
        .help("Pin an app")
    }
}

/// Dashboard-column Quick Apps: a compact row of icons, opening the full
/// launcher when there is more than the row can hold.
struct CompactAppsView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject private var launcher = AppLauncher.shared
    @LNState private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(NotchMotion.content) { model.focus(.apps, from: .dashboard) }
            } label: {
                HStack(spacing: 6) {
                    Text("Quick Apps")
                        .font(Theme.sectionTitle)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.tertiaryText)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                        .opacity(isHovering ? 1 : 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in withAnimation(NotchMotion.quick) { isHovering = hovering } }
            .help("Open Quick Apps")

            let apps = launcher.pinned
            if apps.isEmpty {
                CompactMessage(
                    symbol: "square.grid.2x2",
                    title: "No pinned apps",
                    detail: "Pin apps in Tools ▸ Quick Apps."
                )
            } else {
                HStack(spacing: 7) {
                    ForEach(apps.prefix(5)) { app in
                        Button { launcher.launch(app) } label: {
                            Image(nsImage: launcher.icon(for: app))
                                .resizable().frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                        .help("Open \(app.name)")
                    }
                    if apps.count > 5 {
                        Text("+\(apps.count - 5)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    Spacer(minLength: 0)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
