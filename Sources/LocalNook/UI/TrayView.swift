//
//  TrayView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  The Tray as its own workspace: a visible drop area, real file icons, readable
//  names and clear selection.
//
//  The dashed outline is drawn *inside* the panel, where the Tray is visible.
//  It is not an invisible drop zone floating around the notch — those make the
//  top of the screen unusable, which is exactly what the two-window split exists
//  to prevent.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TrayView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject private var shelf = ShelfStore.shared

    private var isTargeted: Bool { model.isDragTargeting }

    var body: some View {
        VStack(spacing: 6) {
            dropArea
            if !shelf.isEmpty { toolbar }
        }
    }

    private var dropArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(
                    isTargeted ? Theme.accent : Theme.divider,
                    style: StrokeStyle(lineWidth: isTargeted ? 1.6 : 1, dash: [5, 4])
                )
                .background(
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .fill(isTargeted ? Theme.accent.opacity(0.08) : .clear)
                )
                .animation(NotchMotion.quick, value: isTargeted)

            if shelf.isEmpty {
                emptyState
            } else {
                items
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 5) {
            Image(systemName: isTargeted ? "tray.and.arrow.down.fill" : "tray")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(isTargeted ? Theme.accent : Theme.tertiaryText)
                .scaleEffect(isTargeted ? 1.1 : 1)
                .animation(NotchMotion.quick, value: isTargeted)
            Text(isTargeted ? "Drop to add" : "Drag files here")
                .font(Theme.body)
                .foregroundStyle(isTargeted ? Theme.primaryText : Theme.secondaryText)
            if !isTargeted {
                Text("Files stay where they are — the Tray only points at them.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.quaternaryText)
            }
        }
        .padding(.horizontal, 20)
    }

    private var items: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 4) {
                ForEach(shelf.items) { item in
                    TrayTile(item: item, isSelected: shelf.selection.contains(item.id))
                        .onTapGesture {
                            shelf.toggleSelection(
                                item.id, extending: NSEvent.modifierFlags.contains(.command)
                            )
                        }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { shelf.open(item) })
                        .onDrag {
                            // Hand the real file over so it can be dragged back
                            // out to Finder, Mail or anywhere else.
                            if let url = item.url {
                                return NSItemProvider(contentsOf: url) ?? NSItemProvider()
                            }
                            if let payload = item.payload {
                                return NSItemProvider(object: payload as NSString)
                            }
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
            .padding(10)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 9) {
            Text("\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s")")
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiaryText)
            if !shelf.selection.isEmpty {
                Text("· \(shelf.selection.count) selected")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            TrayAction(symbol: "eye", help: "Quick Look") {
                let urls = shelf.selection.isEmpty
                    ? shelf.items.compactMap(\.url) : shelf.selectedURLs
                QuickLookController.shared.preview(urls)
            }
            TrayAction(symbol: "doc.on.clipboard", help: "Paste from clipboard") {
                _ = shelf.pasteFromClipboard()
            }
            if !shelf.selection.isEmpty {
                TrayAction(symbol: "minus.circle", help: "Remove selected") {
                    shelf.removeSelected()
                }
            }
            TrayAction(symbol: "trash", help: "Clear the Tray") { shelf.clearAll() }
        }
        .padding(.horizontal, 2)
    }
}

private struct TrayAction: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @LNState private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovering ? Theme.primaryText : Theme.tertiaryText)
                .frame(width: 22, height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(isHovering ? Theme.surface : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(NotchMotion.quick) { isHovering = hovering } }
        .help(help)
    }
}

private struct TrayTile: View {
    let item: ShelfItem
    let isSelected: Bool

    @LNState private var icon: NSImage?
    @LNState private var isHovering = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 40, height: 40)
                } else {
                    Image(systemName: item.symbol)
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .frame(width: 46, height: 44)

            Text(item.name)
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? Theme.primaryText : Theme.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(width: 62)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 3)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Theme.surfaceActive : (isHovering ? Theme.surface : .clear))
        }
        .overlay {
            if !item.stillExists {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.warning.opacity(0.6), lineWidth: 1)
            }
        }
        .onHover { hovering in withAnimation(NotchMotion.quick) { isHovering = hovering } }
        .help(item.stillExists ? "\(item.name)\n\(item.subtitle)" : "\(item.name)\nFile is missing")
        .task { loadIcon() }
    }

    /// The Finder's own icon — already cached by the system, so this costs
    /// nothing and always matches what the user sees elsewhere.
    private func loadIcon() {
        guard icon == nil, let url = item.url, item.stillExists else { return }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 40, height: 40)
        icon = image
    }
}
