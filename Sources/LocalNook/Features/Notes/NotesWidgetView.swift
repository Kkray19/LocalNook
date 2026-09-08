//
//  NotesWidgetView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import SwiftUI

struct NotesWidgetView: View {
    @ObservedObject private var store = NotesStore.shared
    @LNState private var draft: String = ""
    @LNState private var editingID: UUID?

    var body: some View {
        HStack(spacing: 10) {
            list
                .frame(width: 170)
            Divider().overlay(Color.white.opacity(0.10))
            editor
                .frame(maxWidth: .infinity)
        }
    }

    private var list: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
                TextField("Search", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                Button { store.addNote() } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.6))
                .help("New note")
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.07)))

            if store.filteredNotes.isEmpty {
                Text(store.searchText.isEmpty ? "No notes yet" : "No matches")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(store.filteredNotes) { note in
                            let selected = store.selectedNote?.id == note.id
                            HStack {
                                Text(note.title)
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                                    .foregroundStyle(selected ? .white : .white.opacity(0.65))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(selected ? Color.white.opacity(0.14) : .clear)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                store.selectedNoteID = note.id
                                draft = note.body
                                editingID = note.id
                            }
                            .contextMenu {
                                Button("Delete", role: .destructive) { store.deleteNote(note.id) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var editor: some View {
        Group {
            if let note = store.selectedNote {
                TextEditor(text: Binding(
                    get: { editingID == note.id ? draft : note.body },
                    set: { newValue in
                        draft = newValue
                        editingID = note.id
                        store.updateNote(note.id, body: newValue)
                    }
                ))
                .font(.system(size: 11))
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.05)))
                .foregroundStyle(.white)
                .onAppear {
                    draft = note.body
                    editingID = note.id
                }
            } else {
                VStack(spacing: 5) {
                    Image(systemName: "note.text")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.white.opacity(0.35))
                    Button("New note") { store.addNote() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(0.14)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct TodoWidgetView: View {
    @ObservedObject private var store = NotesStore.shared
    @LNState private var newItem: String = ""

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                TextField("Add a task", text: $newItem)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .onSubmit {
                        store.addTodo(newItem)
                        newItem = ""
                    }
                if store.todos.contains(where: { $0.isDone && !$0.isArchived }) {
                    Button("Archive done") { store.archiveCompleted() }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.07)))

            if store.activeTodos.isEmpty {
                VStack(spacing: 3) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 16, weight: .light))
                        .foregroundStyle(.white.opacity(0.3))
                    Text(store.archivedCount > 0 ? "All clear — \(store.archivedCount) archived" : "Nothing to do")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(store.activeTodos) { item in
                            TodoRow(item: item, store: store)
                        }
                    }
                }
            }
        }
    }
}

private struct TodoRow: View {
    let item: TodoItem
    @ObservedObject var store: NotesStore

    var body: some View {
        HStack(spacing: 8) {
            Button { store.toggleDone(item.id) } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(item.isDone ? Color.accentColor : .white.opacity(0.4))
            }
            .buttonStyle(.plain)

            Text(item.text)
                .font(.system(size: 11))
                .strikethrough(item.isDone, color: .white.opacity(0.4))
                .foregroundStyle(item.isDone ? .white.opacity(0.4) : .white.opacity(0.9))
                .lineLimit(1)

            Spacer(minLength: 4)

            Button { store.toggleFavourite(item.id) } label: {
                Image(systemName: item.isFavourite ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundStyle(item.isFavourite ? .yellow : .white.opacity(0.25))
            }
            .buttonStyle(.plain)

            Button { store.deleteTodo(item.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.045)))
    }
}
