//
//  ShortcutsWidgetView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import SwiftUI

struct ShortcutsWidgetView: View {
    @ObservedObject private var manager = ShortcutsManager.shared
    @LNState private var filter = ""

    private var visible: [ShortcutEntry] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let pinned = manager.pinned
        let rest = manager.shortcuts.filter { !manager.isPinned($0) }
        let ordered = pinned + rest
        guard !query.isEmpty else { return ordered }
        return ordered.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        Group {
            if !manager.isSupported {
                WidgetMessage(
                    symbol: "bolt.slash",
                    title: "Shortcuts unavailable",
                    detail: "The system shortcuts tool could not be found on this Mac."
                )
            } else if manager.isLoading && !manager.hasLoadedOnce {
                ProgressView().controlSize(.small).tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if manager.shortcuts.isEmpty {
                WidgetMessage(
                    symbol: "bolt",
                    title: "No shortcuts found",
                    detail: manager.lastError ?? "Create one in the Shortcuts app and it will appear here.",
                    actionTitle: "Reload"
                ) { manager.reload() }
            } else {
                content
            }
        }
        .onAppear { if !manager.hasLoadedOnce { manager.reload() } }
    }

    private var content: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                TextField("Filter shortcuts", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                Text("\(manager.shortcuts.count)")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
                Button { manager.reload() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9))
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.07)))

            if let error = manager.lastError {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange.opacity(0.9))
                    .lineLimit(2)
            }

            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 5)], spacing: 5) {
                    ForEach(visible) { entry in
                        ShortcutTile(entry: entry, manager: manager)
                    }
                }
            }
        }
    }
}

private struct ShortcutTile: View {
    let entry: ShortcutEntry
    @ObservedObject var manager: ShortcutsManager

    private var isRunning: Bool { manager.runningNames.contains(entry.name) }

    var body: some View {
        Button { manager.run(entry) } label: {
            HStack(spacing: 6) {
                Group {
                    if isRunning {
                        ProgressView().controlSize(.mini).tint(.white)
                    } else {
                        Image(systemName: manager.isPinned(entry) ? "pin.fill" : "bolt.fill")
                            .font(.system(size: 9))
                    }
                }
                .frame(width: 12)
                .foregroundStyle(manager.isPinned(entry) ? .yellow : .white.opacity(0.6))

                Text(entry.name)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
        .contextMenu {
            Button(manager.isPinned(entry) ? "Unpin" : "Pin to top") { manager.togglePin(entry) }
            Button("Open in Shortcuts") { manager.edit(entry) }
        }
        .help("Run “\(entry.name)”")
    }
}
