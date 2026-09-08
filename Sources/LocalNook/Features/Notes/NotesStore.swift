//
//  NotesStore.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Local-only notes and to-dos. Everything lives in a JSON file under
//  ~/Library/Application Support/LocalNook — no sync, no account, no server.
//

import Combine
import Foundation

struct Note: Identifiable, Codable, Equatable {
    let id: UUID
    var body: String
    var updatedAt: Date

    var title: String {
        let firstLine = body
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let trimmed = (firstLine ?? "").trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled note" : String(trimmed.prefix(60))
    }

    static func empty() -> Note {
        Note(id: UUID(), body: "", updatedAt: Date())
    }
}

struct TodoItem: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var isDone: Bool
    var isFavourite: Bool
    var isArchived: Bool
    var createdAt: Date
    var completedAt: Date?

    static func new(_ text: String) -> TodoItem {
        TodoItem(
            id: UUID(), text: text, isDone: false, isFavourite: false,
            isArchived: false, createdAt: Date(), completedAt: nil
        )
    }
}

/// Notes and to-dos, saved to disk with a short debounce so typing does not
/// write a file on every keystroke.
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    @Published var notes: [Note] = []
    @Published var todos: [TodoItem] = []
    @Published var searchText: String = ""
    @Published var selectedNoteID: UUID?

    private var saveTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private var storeURL: URL {
        AppInfo.supportDirectory.appendingPathComponent("notes.json")
    }

    private struct Payload: Codable {
        var notes: [Note]
        var todos: [TodoItem]
    }

    private init() {
        load()
        // Autosave: coalesce bursts of edits into one write.
        Publishers.CombineLatest($notes, $todos)
            .dropFirst()
            .sink { [weak self] _, _ in self?.scheduleSave() }
            .store(in: &cancellables)
    }

    // MARK: Notes

    var filteredNotes: [Note] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = notes.sorted { $0.updatedAt > $1.updatedAt }
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.body.lowercased().contains(query) }
    }

    var selectedNote: Note? {
        guard let selectedNoteID else { return filteredNotes.first }
        return notes.first { $0.id == selectedNoteID } ?? filteredNotes.first
    }

    @discardableResult
    func addNote() -> Note {
        let note = Note.empty()
        notes.insert(note, at: 0)
        selectedNoteID = note.id
        return note
    }

    func updateNote(_ id: UUID, body: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        guard notes[index].body != body else { return }
        notes[index].body = body
        notes[index].updatedAt = Date()
    }

    func deleteNote(_ id: UUID) {
        notes.removeAll { $0.id == id }
        if selectedNoteID == id { selectedNoteID = notes.first?.id }
    }

    // MARK: To-dos

    var activeTodos: [TodoItem] {
        todos
            .filter { !$0.isArchived }
            .sorted { lhs, rhs in
                if lhs.isDone != rhs.isDone { return !lhs.isDone }
                if lhs.isFavourite != rhs.isFavourite { return lhs.isFavourite }
                return lhs.createdAt > rhs.createdAt
            }
    }

    var archivedCount: Int { todos.count { $0.isArchived } }

    func addTodo(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        todos.insert(.new(trimmed), at: 0)
    }

    func toggleDone(_ id: UUID) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].isDone.toggle()
        todos[index].completedAt = todos[index].isDone ? Date() : nil
    }

    func toggleFavourite(_ id: UUID) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].isFavourite.toggle()
    }

    func deleteTodo(_ id: UUID) {
        todos.removeAll { $0.id == id }
    }

    /// Moves everything already ticked off out of the main list.
    func archiveCompleted() {
        for index in todos.indices where todos[index].isDone {
            todos[index].isArchived = true
        }
    }

    func unarchiveAll() {
        for index in todos.indices { todos[index].isArchived = false }
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        let payload = Payload(notes: notes, todos: todos)
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            NSLog("[LocalNook] Could not save notes: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }
        notes = payload.notes
        todos = payload.todos
        selectedNoteID = notes.first?.id
    }
}
