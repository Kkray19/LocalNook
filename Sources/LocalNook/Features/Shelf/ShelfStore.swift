//
//  ShelfStore.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import AppKit
import Combine
import Foundation
import QuickLookUI
import UniformTypeIdentifiers

/// Holds the shelf contents and persists them between launches.
final class ShelfStore: NSObject, ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [ShelfItem] = []
    @Published var selection: Set<UUID> = []

    private var storeURL: URL {
        AppInfo.supportDirectory.appendingPathComponent("shelf.json")
    }

    /// Files LocalNook itself created (dragged text, etc.) live here.
    private var ownedDirectory: URL {
        let dir = AppInfo.supportDirectory.appendingPathComponent("ShelfItems", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private override init() {
        super.init()
        load()
    }

    var isEmpty: Bool { items.isEmpty }

    // MARK: Mutation

    func add(_ item: ShelfItem) {
        // Dropping the same file twice should not duplicate the row.
        if let path = item.path, items.contains(where: { $0.path == path }) { return }
        items.insert(item, at: 0)
        save()
    }

    func add(contentsOf newItems: [ShelfItem]) {
        for item in newItems { add(item) }
    }

    func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        // Only delete files LocalNook created. Never touch the user's own files.
        if item.isOwned, let url = item.url {
            try? FileManager.default.removeItem(at: url)
        }
        items.remove(at: index)
        selection.remove(id)
        save()
    }

    func removeSelected() {
        for id in selection { remove(id) }
        selection.removeAll()
    }

    func clearAll() {
        for item in items where item.isOwned {
            if let url = item.url { try? FileManager.default.removeItem(at: url) }
        }
        items.removeAll()
        selection.removeAll()
        save()
    }

    func toggleSelection(_ id: UUID, extending: Bool) {
        if extending {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = selection == [id] ? [] : [id]
        }
    }

    // MARK: Ingest

    /// Converts a dropped pasteboard into shelf items.
    ///
    /// File URLs are referenced in place. Plain text with no file of its own is
    /// written into LocalNook's storage so it survives a relaunch.
    func ingest(_ pasteboard: NSPasteboard) -> Int {
        var added: [ShelfItem] = []

        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] {
            added += urls.map(ShelfItem.fromFile)
        }

        if added.isEmpty,
           let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            added += urls.filter { !$0.isFileURL }.map(ShelfItem.fromURL)
        }

        if added.isEmpty, let text = pasteboard.string(forType: .string), !text.isEmpty {
            if let url = URL(string: text), url.scheme?.hasPrefix("http") == true {
                added.append(ShelfItem.fromURL(url))
            } else if let item = makeTextItem(text) {
                added.append(item)
            }
        }

        add(contentsOf: added)
        return added.count
    }

    func pasteFromClipboard() -> Int {
        ingest(NSPasteboard.general)
    }

    private func makeTextItem(_ text: String) -> ShelfItem? {
        let firstLine = text
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "Text"
        let name = String(firstLine.prefix(40)).trimmingCharacters(in: .whitespaces)
        let url = ownedDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[LocalNook] Could not store dropped text: \(error.localizedDescription)")
            return nil
        }
        return ShelfItem(
            id: UUID(), kind: .text, name: name.isEmpty ? "Text" : name,
            path: url.path, payload: text, addedAt: Date(), isOwned: true
        )
    }

    // MARK: Actions

    func reveal(_ item: ShelfItem) {
        if item.kind == .url, let payload = item.payload, let url = URL(string: payload) {
            NSWorkspace.shared.open(url)
        } else if let url = item.url {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func open(_ item: ShelfItem) {
        if item.kind == .url, let payload = item.payload, let url = URL(string: payload) {
            NSWorkspace.shared.open(url)
        } else if let url = item.url {
            NSWorkspace.shared.open(url)
        }
    }

    /// Items that can be handed to Quick Look or another app.
    var selectedURLs: [URL] {
        items.filter { selection.contains($0.id) }.compactMap(\.url)
    }

    // MARK: Persistence

    private func save() {
        guard Settings.shared.shelfPersist else { return }
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            NSLog("[LocalNook] Could not save shelf: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard Settings.shared.shelfPersist,
              let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data)
        else { return }
        // Drop entries whose file has since been moved or deleted, so the shelf
        // never shows rows that cannot be acted on.
        items = decoded.filter(\.stillExists)
        if items.count != decoded.count { save() }
    }
}
