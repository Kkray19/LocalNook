//
//  ShelfStore.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import AppKit
import OSLog
import Combine
import Foundation
import QuickLookUI
import UniformTypeIdentifiers

/// Holds the shelf contents and persists them between launches.
final class ShelfStore: NSObject, ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [ShelfItem] = []
    @Published var selection: Set<UUID> = []

    private let file: JSONFileStore<[ShelfItem]>
    @Published private(set) var persistenceError: String?

    /// Files LocalNook itself created (dragged text, etc.) live here.
    private var ownedDirectory: URL {
        let dir = AppInfo.supportDirectory.appendingPathComponent("ShelfItems", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init(storeURL: URL = AppInfo.supportDirectory.appendingPathComponent("shelf.json")) {
        file = JSONFileStore(url: storeURL)
        super.init()
        load()
    }

    var isEmpty: Bool { items.isEmpty }

    // MARK: Mutation

    /// Adds an item, or reports that it was already there.
    ///
    /// - Returns: `true` when the tray actually changed. Callers use this to
    ///   decide whether a drop was handled, so it must reflect what happened
    ///   rather than what was attempted — reporting success for a duplicate
    ///   tells the UI a drop landed while the tray is unchanged.
    @discardableResult
    func add(_ item: ShelfItem) -> Bool {
        // Dropping the same file twice should not duplicate the row.
        if let path = item.path, items.contains(where: { $0.path == path }) { return false }
        items.insert(item, at: 0)
        save()
        return true
    }

    /// - Returns: how many items were actually added.
    @discardableResult
    func add(contentsOf newItems: [ShelfItem]) -> Int {
        newItems.reduce(0) { $0 + (add($1) ? 1 : 0) }
    }

    /// What a drop turned out to be.
    ///
    /// "How many rows appeared" and "was this drop understood" are different
    /// questions, and conflating them makes a duplicate drop look like a broken
    /// one: macOS plays the rejection animation when a drop reports failure, so
    /// re-dropping a file already on the tray would snap back as though nothing
    /// was recognised.
    struct IngestOutcome: Equatable, Sendable {
        var added: Int
        var duplicates: Int

        /// Content LocalNook understood, whether or not it changed the tray.
        var recognised: Int { added + duplicates }
        /// What the drop handler should report to AppKit.
        var wasHandled: Bool { recognised > 0 }
    }

    func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        // Only delete files LocalNook created. Never touch the user's own files.
        if let url = deletableOwnedURL(item) {
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
            if let url = deletableOwnedURL(item) { try? FileManager.default.removeItem(at: url) }
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

        let inserted = add(contentsOf: added)
        lastOutcome = IngestOutcome(added: inserted, duplicates: added.count - inserted)
        return inserted
    }

    /// Full result of the most recent ingest, for the UI's feedback.
    @Published private(set) var lastOutcome: IngestOutcome = IngestOutcome(added: 0, duplicates: 0)

    /// Ingests and reports the complete outcome.
    @discardableResult
    func ingestReportingOutcome(_ pasteboard: NSPasteboard) -> IngestOutcome {
        _ = ingest(pasteboard)
        return lastOutcome
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
            Logger(subsystem: "com.localnook.app", category: "shelf").error("Could not store dropped text")
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

    // Do not trust the persisted ownership flag to authorize arbitrary deletion.
    private func deletableOwnedURL(_ item: ShelfItem) -> URL? {
        guard item.isOwned, let url = item.url, url.isFileURL else { return nil }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let directory = ownedDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.deletingLastPathComponent() == directory else { return nil }
        return resolved
    }

    // MARK: Persistence

    private func save() {
        guard Settings.shared.shelfPersist else { return }
        file.save(items)
        persistenceError = file.failureMessage
    }

    private func load() {
        guard Settings.shared.shelfPersist else { return }
        let decoded = file.load()
        persistenceError = file.failureMessage
        guard let decoded else { return }
        // Drop entries whose file has since been moved or deleted, so the shelf
        // never shows rows that cannot be acted on.
        items = decoded.filter(\.stillExists)
        if items.count != decoded.count { save() }
    }
}
