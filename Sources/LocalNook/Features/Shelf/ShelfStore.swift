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
        // An anchor pointing at a row that no longer exists would make the next
        // shift-click measure from nowhere and silently behave like a plain
        // one. It moves to whatever took the removed row's place — the row
        // below, or the last row when the removed one was at the end — so
        // extending after a removal continues from where the user was.
        if selectionAnchor == id {
            selectionAnchor = items.indices.contains(index) ? items[index].id : items.last?.id
        }
        save()
    }

    func removeSelected() {
        // `remove` mutates `selection`; iterate the copy, not the property.
        for id in Array(selection) { remove(id) }
        clearSelection()
    }

    /// Replaces the contents wholesale. Test-only: the clearing tests need a
    /// known tray and must put the user's back exactly as they found it.
    func restoreForTesting(_ newItems: [ShelfItem]) {
        items = newItems
        clearSelection()
        save()
    }

    // MARK: Clearing

    /// Whether a clear has been asked for and is waiting to be confirmed.
    ///
    /// Clearing the Tray drops every entry and deletes the files LocalNook
    /// itself created. It used to happen on one unguarded click of a trash
    /// icon sitting next to an ordinary "remove selected" button, and during
    /// acceptance that click took thirteen items with it. It now takes two
    /// presses, and the first one expires on its own so an armed button is
    /// never left lying around.
    @Published private(set) var clearIsArmed = false
    private var clearArmTask: Task<Void, Never>?

    /// How long an armed clear stays armed.
    static let clearArmingWindow: Duration = .seconds(4)

    func requestClear() {
        guard !items.isEmpty else { return }
        clearIsArmed = true
        clearArmTask?.cancel()
        clearArmTask = Task { [weak self] in
            try? await Task.sleep(for: Self.clearArmingWindow)
            guard !Task.isCancelled else { return }
            self?.clearIsArmed = false
            self?.clearArmTask = nil
        }
    }

    func cancelClear() {
        clearArmTask?.cancel()
        clearArmTask = nil
        clearIsArmed = false
    }

    /// Clears only when a clear was asked for first. Returns whether it did.
    ///
    /// The gate lives here rather than in the view so it cannot be skipped by
    /// a second call site added later.
    @discardableResult
    func confirmClear() -> Bool {
        guard clearIsArmed else { return false }
        cancelClear()
        clearAll()
        return true
    }

    func clearAll() {
        for item in items where item.isOwned {
            if let url = deletableOwnedURL(item) { try? FileManager.default.removeItem(at: url) }
        }
        items.removeAll()
        clearSelection()
        save()
    }

    // MARK: Selection

    /// Where a shift-click measures from.
    ///
    /// macOS extends from the last row clicked *without* shift, not from the
    /// edge of the current selection, so shift-clicking twice in a row grows
    /// and shrinks one range rather than ratcheting outwards.
    @Published private(set) var selectionAnchor: UUID?

    /// Which selection a click means, by the keys held with it.
    enum SelectionGesture: Equatable {
        /// A plain click: this row and nothing else.
        case replace
        /// Command: add or remove this row, leave the rest alone.
        case toggle
        /// Shift: everything between the anchor and this row.
        case extend

        static func from(_ flags: NSEvent.ModifierFlags) -> SelectionGesture {
            if flags.contains(.shift) { return .extend }
            if flags.contains(.command) { return .toggle }
            return .replace
        }
    }

    /// The selection arithmetic on its own, so every rule can be asserted
    /// without a view, an event, or a click.
    ///
    /// - Returns: the new selection and the new anchor.
    static func selection(
        after gesture: SelectionGesture,
        clicking id: UUID,
        in order: [UUID],
        current: Set<UUID>,
        anchor: UUID?
    ) -> (selection: Set<UUID>, anchor: UUID?) {
        // A click on a row that is no longer there must not invent a selection.
        guard order.contains(id) else { return (current, anchor) }

        switch gesture {
        case .replace:
            // Clicking the single selected row clears it. The tray row has no
            // empty space to click, so without this there is no way to deselect
            // with the mouse at all.
            if current == [id] { return ([], nil) }
            return ([id], id)

        case .toggle:
            var next = current
            if next.contains(id) { next.remove(id) } else { next.insert(id) }
            // The anchor follows the command-click, so a shift-click after one
            // measures from where the user last actually pointed.
            return (next, id)

        case .extend:
            // Shift with nothing to measure from behaves like a plain click,
            // which is what Finder does on a fresh list.
            guard let anchor, let from = order.firstIndex(of: anchor),
                  let to = order.firstIndex(of: id)
            else { return ([id], id) }
            let span = from <= to ? from...to : to...from
            return (Set(order[span]), anchor)
        }
    }

    func select(_ id: UUID, gesture: SelectionGesture) {
        let result = Self.selection(
            after: gesture, clicking: id, in: items.map(\.id),
            current: selection, anchor: selectionAnchor
        )
        selection = result.selection
        selectionAnchor = result.anchor
    }

    /// Kept for the compact shelf column, which has only a modifier flag to
    /// offer. Command-click semantics, by the old name.
    func toggleSelection(_ id: UUID, extending: Bool) {
        select(id, gesture: extending ? .toggle : .replace)
    }

    func selectAll() {
        selection = Set(items.map(\.id))
        selectionAnchor = items.first?.id
    }

    func clearSelection() {
        selection.removeAll()
        selectionAnchor = nil
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

    // MARK: Handing items to another app

    /// What a drag out of the Tray would carry: the selection, or everything
    /// when nothing is picked. "Drag all" is the sensible reading of a shelf
    /// nobody has selected within.
    var itemsToHandOff: [ShelfItem] {
        selection.isEmpty ? items : items.filter { selection.contains($0.id) }
    }

    /// Those of them another app will actually accept — existing files and real
    /// links, deduplicated. See ShelfDrag.
    var handOffURLs: [URL] { ShelfDrag.urls(for: itemsToHandOff) }

    /// How many of the chosen items cannot travel, so the UI can say so.
    var handOffMissingCount: Int { ShelfDrag.missingCount(in: itemsToHandOff) }

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
