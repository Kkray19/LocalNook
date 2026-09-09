//
//  SessionDetail.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  What an agent session is doing, read from its own transcript.
//
//  ── This reads content, and is treated as such ──────────────────────────────
//
//  A chat title and a tool description are written by a person, or by a model
//  reasoning about that person's work. They can name a client, a repository, a
//  medical question, an unreleased product. Truncating them to ninety
//  characters makes them shorter, not safer. So they are handled as *content*,
//  not as metadata that happens to live in a file:
//
//    * Off by default. `Settings.sessionLabelDepth` starts at `.metadataOnly`,
//      in which not one byte of any transcript body is read. Switching the
//      sessions widget on is not consent to read inside transcripts.
//    * Strictly extracted. Four named fields and nothing else. There is no
//      fallback to message text, assistant prose or user input — if the named
//      field is absent then the value is absent, and the UI says so.
//    * Never printed. Not logged, not written to diagnostics, not included in
//      `--render-preview` output, never persisted. The only cache is in memory
//      and is dropped the moment the feature is switched off.
//    * Not shown on a locked screen, and not even read while locked.
//
//  ── Reads are bounded, and the bound is a real limitation ──────────────────
//
//  Transcripts on this machine reach 40 MB. The reader takes a 256 KB tail and,
//  only when the title has not already been seen, a 512 KB head. That is a
//  *sample*, and sampling has consequences worth stating rather than hiding:
//
//    * A title set unusually late — past the head window but before the tail
//      window — is not found, and the session shows its directory name instead.
//      That is a miss, and it is reported as an absent title rather than filled
//      in with a guess.
//    * A session whose last 256 KB holds no assistant record yields no step. A
//      single very large record can cause this.
//    * The head and the tail can come from far apart in a long conversation.
//      Nothing is inferred across that gap: the model, the effort and the step
//      are all taken from one record, so they cannot describe different turns.
//

import Foundation

/// How much of a transcript the sessions widget may read.
nonisolated enum SessionLabelDepth: String, CaseIterable, Identifiable, Sendable {
    /// File metadata only. No transcript body is opened.
    case metadataOnly
    /// The four named fields, read from the transcript.
    case richLabels

    var id: String { rawValue }

    var label: String {
        switch self {
        case .metadataOnly: "Metadata only"
        case .richLabels: "Read labels from session files"
        }
    }

    var explanation: String {
        switch self {
        case .metadataOnly:
            "Sessions are described by file name and timestamp only. No "
                + "transcript content is read."
        case .richLabels:
            "LocalNook reads four fields from your local session files — the "
                + "model, the effort, the name you gave the chat, and the current "
                + "step — and uses them as labels. Those fields can contain "
                + "anything you or the agent wrote. They stay on this Mac, are "
                + "never saved or logged, and are not shown on the lock screen."
        }
    }
}

/// How confident we are that a session is doing something *now*.
nonisolated enum SessionActivityState: String, Equatable, Sendable {
    /// A record timestamped inside the working window. The step is current.
    case working
    /// Recent enough to list, but the newest record is too old to claim its
    /// step still describes what is happening.
    case recent
    /// No authoritative timestamp — the transcript did not provide one.
    case unknown
}

/// The parts of a session worth showing. Every field is optional, and absent
/// means absent: nothing here is guessed or substituted.
nonisolated struct SessionDetail: Equatable, Sendable {
    var model: String?
    var effort: String?
    var title: String?
    /// The current step. Only ever populated when `activity == .working`.
    var step: String?
    var activity: SessionActivityState = .unknown
    /// True when the reader was not permitted to look, as distinct from looking
    /// and finding nothing. Keeps "switched off" distinguishable from "empty".
    var wasNotRead = true

    var isEmpty: Bool { model == nil && effort == nil && title == nil && step == nil }

    /// "Opus 5 max". Absent when the model is unknown — never a placeholder.
    var modelLabel: String? {
        guard let model else { return nil }
        guard let effort else { return model }
        return "\(model) \(effort)"
    }

    /// Whether the marching indicator should run. It must not imply work is in
    /// progress on the strength of a stale tool description.
    var showsProgress: Bool { activity == .working && step != nil }
}

/// Reads `SessionDetail` from a transcript without ever reading all of it.
nonisolated enum SessionDetailReader {
    static let tailWindow = 256 * 1024
    static let headWindow = 512 * 1024
    /// Labels are labels. Anything longer is a body, and is cut.
    static let maxLabelLength = 90
    /// How fresh the newest record must be for its step to count as current.
    static let workingWindow: TimeInterval = 120

    /// Reads a transcript, or declines to.
    ///
    /// Declines — returning `wasNotRead` — when the feature is off or the screen
    /// is locked. Both are checked here rather than at the call sites, so a
    /// caller added later cannot bypass them by forgetting.
    static func read(path: String, agent: SessionAgent, depth: SessionLabelDepth) -> SessionDetail {
        guard depth == .richLabels else { return SessionDetail() }
        guard !ScreenLock.isLocked else { return SessionDetail() }

        var detail: SessionDetail
        switch agent {
        case .claudeCode: detail = readClaudeCode(path: path)
        case .codex: detail = readCodex(path: path)
        }
        detail.wasNotRead = false
        return detail
    }

    // MARK: Claude Code

    private static func readClaudeCode(path: String) -> SessionDetail {
        var detail = SessionDetail()

        // The newest assistant record, kept whole, so the model, the effort and
        // the step all describe the same turn. Taking each from wherever it last
        // appeared would let a model name from one turn sit beside a step from
        // another and read as a single coherent statement.
        var newestAssistant: [String: Any]?

        for line in lines(atPath: path, window: tailWindow, fromEnd: true) {
            guard let object = json(line) else { continue }
            switch object["type"] as? String {
            case "assistant":
                newestAssistant = object
            case "custom-title":
                if let title = object["customTitle"] as? String { detail.title = label(title) }
            default:
                break
            }
        }

        if let record = newestAssistant {
            let message = record["message"] as? [String: Any]
            if let model = message?["model"] as? String {
                detail.model = displayName(forModel: model)
            }
            if let effort = record["effort"] as? String, !effort.isEmpty {
                detail.effort = label(effort)
            }
            detail.activity = state(forTimestamp: record["timestamp"] as? String)
            // The step only means anything while the turn is current.
            if detail.activity == .working {
                detail.step = currentStep(inClaudeContent: message?["content"])
            }
        }

        if detail.title == nil {
            for line in lines(atPath: path, window: headWindow, fromEnd: false) {
                guard let object = json(line),
                      object["type"] as? String == "custom-title",
                      let title = object["customTitle"] as? String
                else { continue }
                detail.title = label(title)
            }
        }
        return detail
    }

    /// The step, from named fields only.
    ///
    /// A tool call's `description` is the label the agent's own progress line
    /// shows, and the tool's `name` is a verb. There is deliberately no third
    /// case: falling back to assistant prose would put arbitrary generated text
    /// on the menu bar, which is exactly what this boundary exists to prevent.
    private static func currentStep(inClaudeContent content: Any?) -> String? {
        guard let blocks = content as? [[String: Any]] else { return nil }
        for block in blocks.reversed() where block["type"] as? String == "tool_use" {
            if let description = (block["input"] as? [String: Any])?["description"] as? String,
               let text = label(description) {
                return text
            }
            if let name = block["name"] as? String, let text = label(name) {
                return text
            }
        }
        return nil
    }

    // MARK: Codex

    /// Codex records everything in named fields, and this reads six of them.
    ///
    /// An earlier version of this function read only the model, on the stated
    /// grounds that Codex "has no equivalent of a tool description" and that
    /// its payloads "carry raw assistant and user text". The second half is
    /// true and is why `Reasoning`, `AgentMessage` and `UserMessage` items are
    /// skipped below. The first half was wrong: `item_completed` carries a
    /// structured `item`, and both of its tool-shaped kinds expose named
    /// identifiers — `McpToolCall.tool` and `CommandExecution.parsed_cmd[].type`
    /// — which are the same sort of thing as Claude's tool name.
    ///
    /// The consequence of that mistake was that a Codex session could never
    /// report what it was doing, and never showed as working. It appeared in
    /// the list as a bare timestamp.
    ///
    /// Codex is also more definite than Claude about whether a turn is running:
    /// `task_started` and `task_complete` carry a `turn_id`, so an unmatched
    /// start means a turn is genuinely in flight. That is still combined with
    /// transcript freshness, because a killed process leaves its last turn open
    /// forever and the file simply stops.
    private static func readCodex(path: String) -> SessionDetail {
        var detail = SessionDetail()
        var newestTimestamp: String?
        var openTurns: Set<String> = []
        var newestStep: String?

        for line in lines(atPath: path, window: tailWindow, fromEnd: true) {
            guard let object = json(line) else { continue }
            if let stamp = object["timestamp"] as? String { newestTimestamp = stamp }
            guard let payload = object["payload"] as? [String: Any] else { continue }

            switch object["type"] as? String {
            case "turn_context":
                if let model = payload["model"] as? String {
                    detail.model = displayName(forModel: model)
                }
                // "high" / "medium" / "low" — the same short token Claude writes.
                if let effort = payload["effort"] as? String { detail.effort = label(effort) }
                // The working directory, which is what Claude sessions already
                // show. Claude's comes free from the path; Codex files are
                // grouped by date instead, so without this a session is called
                // "2026-09-08T00". Behind the same consent as every other field
                // read from inside a transcript.
                if let cwd = payload["cwd"] as? String { detail.title = projectLabel(forPath: cwd) }
            case "event_msg":
                switch payload["type"] as? String {
                case "task_started":
                    if let turn = payload["turn_id"] as? String { openTurns.insert(turn) }
                case "task_complete":
                    if let turn = payload["turn_id"] as? String { openTurns.remove(turn) }
                case "item_completed":
                    if let item = payload["item"] as? [String: Any],
                       let step = codexStep(forItem: item) {
                        newestStep = step
                    }
                default:
                    break
                }
            default:
                break
            }
        }

        detail.activity = state(forTimestamp: newestTimestamp)
        // Both, deliberately. An open turn says Codex believes it is working; a
        // fresh timestamp says the transcript agrees. One without the other is
        // a transcript that stopped mid-turn.
        if detail.activity == .working, openTurns.isEmpty { detail.activity = .recent }
        if detail.activity == .working { detail.step = newestStep }
        return detail
    }

    /// The step for one Codex item, from named identifiers only.
    ///
    /// Nothing here can carry free text. A command's own text is deliberately
    /// not used — a command line is full of paths, filenames and search terms —
    /// so `CommandExecution` contributes only the verb Codex itself parsed out
    /// of it, rendered in LocalNook's words rather than the transcript's.
    static func codexStep(forItem item: [String: Any]) -> String? {
        switch item["type"] as? String {
        case "McpToolCall":
            // An identifier such as "sites.get_deployment_status", not arguments.
            if let tool = item["tool"] as? String, let text = label(tool) { return text }
            if let action = item["actionName"] as? String, let text = label(action) { return text }
            return nil
        case "CommandExecution":
            guard let parsed = item["parsed_cmd"] as? [[String: Any]] else { return nil }
            for entry in parsed.reversed() {
                switch entry["type"] as? String {
                case "read": return "Reading a file"
                case "list_files": return "Listing files"
                case "search": return "Searching"
                case "unknown": return "Running a command"
                default: continue
                }
            }
            return nil
        default:
            // Reasoning, AgentMessage, UserMessage. All prose.
            return nil
        }
    }

    /// The last component of a working directory, as a label.
    ///
    /// A path, reduced to the folder name — the same thing a Claude session
    /// shows. Anything that is not a plain directory name is refused rather
    /// than passed through.
    static func projectLabel(forPath path: String) -> String? {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let last = trimmed.split(separator: "/").last else { return nil }
        return label(String(last))
    }

    // MARK: Shared

    /// Freshness from the transcript's own timestamp, which is authoritative in
    /// a way the file's modification date is not: a file can be touched by a
    /// backup, a search index or an editor without the session doing anything.
    static func state(forTimestamp raw: String?) -> SessionActivityState {
        guard let raw, let date = parseTimestamp(raw) else { return .unknown }
        let age = Date().timeIntervalSince(date)
        // A timestamp in the future is a clock problem, not freshness.
        guard age >= -60 else { return .unknown }
        return age < workingWindow ? .working : .recent
    }

    /// Formatters are not Sendable and the reader runs off the main actor, so
    /// each parse builds its own rather than sharing one across threads.
    private static func parseTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static func lines(atPath path: String, window: Int, fromEnd: Bool) -> [Substring] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        guard size > 0 else { return [] }
        let length = min(window, size)

        if fromEnd {
            try? handle.seek(toOffset: UInt64(size - length))
        } else {
            try? handle.seek(toOffset: 0)
        }
        guard let data = try? handle.read(upToCount: length),
              let text = String(data: data, encoding: .utf8)
        else { return [] }

        var pieces = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !pieces.isEmpty else { return [] }
        // Drop whichever piece the window cut in half, so a partially written
        // record is never parsed as though it were complete.
        if fromEnd, length < size { pieces.removeFirst() }
        if !fromEnd, length < size { pieces.removeLast() }
        return pieces
    }

    private static func json(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Normalises a field into something displayable, or into nothing.
    ///
    /// Control characters are stripped: a transcript is machine-written, and a
    /// stray newline or escape sequence in a menu-bar label is a rendering
    /// problem at best.
    static func label(_ text: String) -> String? {
        let firstLine = text.components(separatedBy: .newlines).first ?? ""
        let scalars = firstLine.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && !$0.properties.isDefaultIgnorableCodePoint
        }
        let stripped = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty else { return nil }
        guard stripped.count > maxLabelLength else { return stripped }
        return String(stripped.prefix(maxLabelLength - 1)) + "…"
    }

    /// "claude-opus-5" → "Opus 5". Identifiers only: this maps a machine name
    /// and refuses anything that does not look like one, so it can never become
    /// a channel for free text.
    static func displayName(forModel identifier: String) -> String? {
        let id = identifier.lowercased()
        guard !id.isEmpty, !id.hasPrefix("<"), id.count <= 60 else { return nil }
        guard id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "_" })
        else { return nil }

        var parts = id.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        if let first = parts.first, ["claude", "anthropic"].contains(first) { parts.removeFirst() }
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard !parts.isEmpty else { return nil }

        var name = parts.removeFirst()
        name = name == "gpt" ? "GPT" : name.capitalized
        let numbers = parts.filter { Int($0) != nil }
        let words = parts.filter { Int($0) == nil }
        var result = name
        if !numbers.isEmpty { result += " " + numbers.joined(separator: ".") }
        if !words.isEmpty { result += " " + words.map(\.capitalized).joined(separator: " ") }
        return result
    }
}

/// Remembers what was read from each transcript, so an unchanged file is not
/// reopened on every scan.
///
/// In memory only, and deliberately so. Writing these strings to disk would
/// turn a transient label into a persistent copy of someone's chat titles,
/// which is precisely the thing the boundary above exists to avoid. The cache
/// is dropped whole when the feature is switched off.
final class SessionDetailCache: @unchecked Sendable {
    private struct Key: Hashable {
        let path: String
        let size: Int
        let modified: TimeInterval
    }

    private var entries: [Key: SessionDetail] = [:]
    private let lock = NSLock()

    func detail(forPath path: String, size: Int, modified: Date) -> SessionDetail? {
        lock.lock()
        defer { lock.unlock() }
        return entries[Key(path: path, size: size, modified: modified.timeIntervalSince1970)]
    }

    func store(_ detail: SessionDetail, forPath path: String, size: Int, modified: Date) {
        lock.lock()
        defer { lock.unlock() }
        // A session that changes constantly would otherwise accumulate an entry
        // per write. Bounded, and the bound is small because only a handful of
        // sessions are ever read.
        if entries.count > 64 { entries.removeAll() }
        entries[Key(path: path, size: size, modified: modified.timeIntervalSince1970)] = detail
    }

    /// Forgets everything. Called when the feature is switched off, so no label
    /// outlives the permission that produced it.
    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.isEmpty
    }
}
