//
//  ChatGPTCatalogReader.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  ChatGPT chats, as the ChatGPT desktop app lists them locally.
//
//  ── What this is, and what it cannot be ─────────────────────────────────────
//
//  A ChatGPT chat runs in OpenAI's cloud and leaves no transcript on this Mac,
//  which is why it never appeared beside Claude Code and Codex. The desktop app
//  does keep its own list of your chats, in `~/.codex/sqlite/codex-dev.db`, and
//  updates it while it is open — within about two seconds of a chat changing,
//  measured on this Mac. That list says when each chat was last updated and
//  what it is called. It does not say whether a reply is being written, which
//  model is answering, or what step it is on. So a chat can be shown as
//  recently active, never as working: no spinner, no step.
//
//  ── Built to fail closed ───────────────────────────────────────────────────
//
//  This is another app's private database. Its schema is not published and has
//  been migrated 28 times already, so every assumption is checked rather than
//  trusted, and anything unfamiliar produces no sessions and a status saying
//  why — never a crash, a partial list, or a guess:
//
//    * Read-only twice over: the `mode=ro` URI parameter and the read-only open
//      flag. Either alone refuses a write; together, a mistake in one cannot
//      become a write to someone else's data. A missing file is never created.
//    * The write-ahead log is read, not bypassed. `immutable=1` would avoid
//      needing the shared-memory file, and would also silently return data
//      from before the app's last checkpoint — a stale "last updated" is the
//      one wrong answer this exists to avoid.
//    * A 250 ms busy timeout, so an app mid-write delays a scan rather than
//      failing it.
//    * Columns are verified before any query is built. The SQL is assembled
//      only from names checked against the schema, never from data.
//    * Every row is validated: an identifier that is not identifier-shaped, a
//      timestamp that is not a finite positive number, or one from the future,
//      is skipped. A future timestamp would hold a chat "live" until the clock
//      caught up.
//    * A read error part-way through returns nothing. A partial list could
//      omit exactly the chat that is live, and would look complete.
//
//  ── Privacy ────────────────────────────────────────────────────────────────
//
//  Chat titles are content, so they are read only when session labels are on
//  and the screen is unlocked, and are cleaned like every other label. The
//  catalog's host identifiers contain account identifiers; they are used only
//  to exclude this Mac's own threads, and never leave this file.
//
//  Threads on the `local` host are excluded outright: those are the desktop
//  app's own agent runs, which write transcripts and already arrive as Codex
//  sessions. Including them would count each one twice.
//

import Foundation
import SQLite3

nonisolated enum ChatGPTCatalogReader {
    /// At most this many chats, so a busy week of conversations cannot push
    /// agent sessions out of the list.
    static let maximumSessions = 10
    /// The same window transcripts are listed for.
    static let window: TimeInterval = 7 * 86400
    /// Longer than any identifier the app has written. Anything bigger is not
    /// an identifier, whatever the column says.
    static let maximumIdentifierLength = 100

    static var defaultDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sqlite/codex-dev.db", isDirectory: false)
    }

    /// How the last read went, for the settings pane and the probe.
    nonisolated enum Status: Equatable, Sendable {
        case ok(count: Int)
        /// No database: the app is not installed, or has never been opened.
        case missing
        /// The file exists but could not be opened or read.
        case unreadable
        /// The table or a column this relies on is gone.
        case formatChanged(String)

        var summary: String {
            switch self {
            case .ok(let count):
                count == 0
                    ? "No ChatGPT chats updated this week."
                    : "Reading \(count) recent ChatGPT chat\(count == 1 ? "" : "s")."
            case .missing:
                "The ChatGPT desktop app's chat list was not found. Open the app once to create it."
            case .unreadable:
                "The ChatGPT chat list could not be read, so nothing is shown rather than a guess."
            case .formatChanged(let reason):
                "The ChatGPT chat list has changed format (\(reason)), so nothing is shown rather than a guess."
            }
        }
    }

    nonisolated struct Result: Sendable {
        var sessions: [AgentSession]
        var status: Status
    }

    static func read(
        database: URL = defaultDatabase,
        depth: SessionLabelDepth,
        now: Date = Date()
    ) -> Result {
        guard FileManager.default.fileExists(atPath: database.path) else {
            return Result(sessions: [], status: .missing)
        }

        var handle: OpaquePointer?
        let uri = database.absoluteString + "?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close_v2(handle)
            return Result(sessions: [], status: .unreadable)
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 250)

        // A file that is not a database opens without complaint and fails on
        // its first statement, so this is also where corruption shows up.
        guard let catalog = columns(of: "local_thread_catalog", in: db) else {
            return Result(sessions: [], status: .unreadable)
        }
        guard !catalog.isEmpty else {
            return Result(sessions: [], status: .formatChanged("its chat table is gone"))
        }
        let missing = ["thread_id", "source_updated_at", "host_id"].filter { !catalog.contains($0) }
        guard missing.isEmpty else {
            return Result(sessions: [],
                          status: .formatChanged("missing \(missing.joined(separator: ", "))"))
        }

        let readsTitles = depth == .richLabels && !ScreenLock.isLocked
            && catalog.contains("display_title")

        // The literal `local` host is always excluded; where the hosts table
        // says which hosts are local, those are excluded too.
        var exclusion = "host_id <> 'local'"
        let hosts = columns(of: "local_thread_catalog_hosts", in: db) ?? []
        if hosts.contains("host_id"), hosts.contains("host_kind") {
            exclusion += " AND host_id NOT IN "
                + "(SELECT host_id FROM local_thread_catalog_hosts WHERE host_kind = 'local')"
        }
        let sql = "SELECT thread_id, source_updated_at\(readsTitles ? ", display_title" : "") "
            + "FROM local_thread_catalog WHERE \(exclusion) "
            + "ORDER BY source_updated_at DESC LIMIT 60"

        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK,
              let statement = prepared
        else {
            sqlite3_finalize(prepared)
            return Result(sessions: [], status: .unreadable)
        }
        defer { sqlite3_finalize(statement) }

        var sessions: [AgentSession] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return Result(sessions: [], status: .unreadable) }

            guard let threadID = text(statement, 0), isIdentifier(threadID),
                  sqlite3_column_type(statement, 1) != SQLITE_NULL,
                  let updated = date(fromStored: sqlite3_column_double(statement, 1))
            else { continue }
            let age = now.timeIntervalSince(updated)
            guard age >= -60, age < window else { continue }

            var session = AgentSession(
                id: "chatgpt:\(threadID)", agent: .chatGPT, projectName: "ChatGPT chat",
                lastActivity: updated, byteSize: 0
            )
            // Recent, never working: nothing in this list says a reply is in
            // flight, and the notch must not claim one on the strength of a
            // timestamp.
            session.detail.activity = .recent
            session.detail.wasNotRead = !readsTitles
            if readsTitles, let raw = text(statement, 2) {
                session.detail.title = SessionDetailReader.label(raw)
            }
            sessions.append(session)
        }

        // Stored units are not guaranteed, so the database's order is only
        // approximately right. Sorted on the normalised dates instead.
        sessions.sort { $0.lastActivity > $1.lastActivity }
        let kept = Array(sessions.prefix(maximumSessions))
        return Result(sessions: kept, status: .ok(count: kept.count))
    }

    /// Seconds or milliseconds since the epoch, whichever it turns out to be.
    static func date(fromStored value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 1e12 ? value / 1000 : value)
    }

    static func isIdentifier(_ value: String) -> Bool {
        guard (1...maximumIdentifierLength).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "-_.:".unicodeScalars.contains($0)
        }
    }

    /// A table's column names; empty when there is no such table; nil when the
    /// file cannot be read at all. Only ever called with constant names.
    private static func columns(of table: String, in db: OpaquePointer) -> Set<String>? {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &prepared, nil) == SQLITE_OK,
              let statement = prepared
        else {
            sqlite3_finalize(prepared)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return names }
            guard step == SQLITE_ROW else { return nil }
            if let name = text(statement, 1) { names.insert(name) }
        }
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }
}
