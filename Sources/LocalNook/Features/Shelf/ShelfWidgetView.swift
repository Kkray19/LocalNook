//
//  ShelfWidgetView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShelfWidgetView: View {
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject var model: NotchViewModel

    var body: some View {
        VStack(spacing: 6) {
            if shelf.isEmpty {
                empty
            } else {
                itemStrip
                toolbar
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 5) {
            Image(systemName: model.isDragTargeting ? "tray.and.arrow.down.fill" : "tray")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.white.opacity(model.isDragTargeting ? 0.85 : 0.35))
                .scaleEffect(model.isDragTargeting ? 1.12 : 1)
                .animation(NotchMotion.quick, value: model.isDragTargeting)
            Text(model.isDragTargeting ? "Drop to add" : "Drag files here")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text("Files, folders, images, links or text. Nothing is copied — items point at where they already live.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 30)
    }

    private var itemStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(shelf.items) { item in
                    ShelfTile(item: item, isSelected: shelf.selection.contains(item.id))
                        .onTapGesture {
                            shelf.toggleSelection(
                                item.id,
                                extending: NSEvent.modifierFlags.contains(.command)
                            )
                        }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { shelf.open(item) })
                        .onDrag {
                            // Hand the real file to the receiving app, so items
                            // can be dragged straight back out to Finder or Mail.
                            if let url = item.url { return NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                            if let payload = item.payload { return NSItemProvider(object: payload as NSString) }
                            return NSItemProvider()
                        }
                        .contextMenu {
                            Button("Open") { shelf.open(item) }
                            Button("Reveal in Finder") { shelf.reveal(item) }
                            if item.url != nil {
                                Button("Quick Look") {
                                    QuickLookController.shared.preview([item.url].compactMap { $0 })
                                }
                            }
                            Divider()
                            Button("Remove", role: .destructive) { shelf.remove(item.id) }
                        }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s")")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))

            if !shelf.selection.isEmpty {
                Text("· \(shelf.selection.count) selected")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()

            ShelfActionButton(symbol: "eye", help: "Quick Look") {
                let urls = shelf.selection.isEmpty
                    ? shelf.items.compactMap(\.url)
                    : shelf.selectedURLs
                QuickLookController.shared.preview(urls)
            }
            .disabled(shelf.items.compactMap(\.url).isEmpty)

            ShelfActionButton(symbol: "doc.on.clipboard", help: "Paste from clipboard") {
                _ = shelf.pasteFromClipboard()
            }

            if !shelf.selection.isEmpty {
                ShelfActionButton(symbol: "minus.circle", help: "Remove selected") {
                    shelf.removeSelected()
                }
            }

            ShelfActionButton(symbol: "trash", help: "Clear the shelf") {
                shelf.clearAll()
            }
        }
    }
}

private struct ShelfActionButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    let isSelected: Bool

    @LNState private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.08))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else {
                    Image(systemName: item.symbol)
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: 56, height: 46)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : .white.opacity(0.10),
                            lineWidth: isSelected ? 1.5 : 0.5)
            }

            Text(item.name)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 58)
        }
        .help("\(item.name)\n\(item.subtitle)")
        .task { loadThumbnail() }
    }

    /// Uses the Finder's own icon, which is already cached by the system and
    /// costs nothing to ask for.
    private func loadThumbnail() {
        guard thumbnail == nil, let url = item.url, item.stillExists else { return }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 40, height: 40)
        thumbnail = icon
    }
}
