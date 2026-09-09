//
//  SessionDetail.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  What an agent session is *actually* doing, read from its own transcript.
//
//  Until now a session was described entirely by file metadata, so the notch
//  showed a directory name — often a workspace hash like "3274fa", which tells
//  you nothing. The transcript itself carries the model, the effort, the name
//  you gave the chat and what the agent is working on right now.
//
//  Privacy, deliberately narrow:
//
//    * Reads are bounded. Transcripts reach tens of megabytes; this reads at
//      most a 256 KB tail and, once per file, a 512 KB head. It never reads a
//      whole file and never holds one in memory.
//    * Only four short strings are extracted, each truncated. Message bodies,
//      tool inputs, file contents and command output are not retained.
//    * Nothing is written anywhere. The strings live in memory for as long as
//      the widget shows them and are never persisted, logged or sent.
//
//  This is a real widening of what LocalNook reads — it was previously metadata
//  only — so it is stated here rather than left to be discovered. It stays on
//  this Mac, like everything else.
//

import Foundation

/// The parts of a session worth showing. Every field is optional: an
/// unrecognised transcript degrades to the old metadata-only behaviour rather
/// than guessing.
nonisolated struct SessionDetail: Equatable, Sendable {
    /// Display name of the model, e.g. "Opus 5".
    var model: String?
    /// Reasoning effort, when the transcript records one, e.g. "max".
    var effort: String?
    /// The name given to the chat, when there is one.
    var title: String?
    /// A short description of the current step, e.g. "Running the test suite".
    var activity: String?

    var isEmpty: Bool {
        model == nil && effort == nil && title == nil && activity == nil
    }

    /// "Opus 5 max" — what the collapsed live activity shows instead of a
    /// directory name.
    var modelLabel: String? {
        guard let model else { return nil }
        guard let effort else { return model }
        return "\(model) \(effort)"
    }
}

/// Reads `SessionDetail` from a transcript without ever reading all of it.
nonisolated enum SessionDetailReader {
    /// Enough tail to hold the last few exchanges. Measured against a 40 MB
    /// transcript: model, effort and the current step were all recovered.
    static let tailWindow = 256 * 1024
    /// The chat name is written early — 0.4% into that same 40 MB file — so a
    /// head window finds it without touching the rest.
    static let headWindow = 512 * 1024
    /// Activity strings are labels, not content. Anything longer is a message
    /// body that has no business here.
    static let maxActivityLength = 90

    static func read(path: String, agent: SessionAgent) -> SessionDetail {
        switch agent {
        case .claudeCode: readClaudeCode(path: path)
        case .codex: readCodex(path: path)
        }
    }

    // MARK: Claude Code

    private static func readClaudeCode(path: String) -> SessionDetail {
        var detail = SessionDetail()

        for line in lines(atPath: path, window: tailWindow, fromEnd: true) {
            guard let object = json(line) else { continue }

            if let message = object["message"] as? [String: Any],
               let model = message["model"] as? String,
               !model.hasPrefix("<") {                      // "<synthetic>"
                detail.model = displayName(forModel: model)
            }
            if let effort = object["effort"] as? String, !effort.isEmpty {
                detail.effort = effort
            }
            if object["type"] as? String == "custom-title",
               let title = object["customTitle"] as? String {
                detail.title = trimmed(title)
            }
            if object["type"] as? String == "assistant",
               let message = object["message"] as? [String: Any],
               let step = currentStep(inClaudeContent: message["content"]) {
                detail.activity = step
            }
        }

        // The title is set near the start, so it is usually outside the tail.
        if detail.title == nil {
            for line in lines(atPath: path, window: headWindow, fromEnd: false) {
                guard let object = json(line),
                      object["type"] as? String == "custom-title",
                      let title = object["customTitle"] as? String
                else { continue }
                detail.title = trimmed(title)
            }
        }
        return detail
    }

    /// What the agent is doing, from the newest assistant message.
    ///
    /// A tool call's own `description` is the same short label the agent's UI
    /// shows on its progress line, which is exactly what belongs here. Falling
    /// back to the tool's name keeps it to a verb. Prose is a last resort and
    /// is cut to one line.
    private static func currentStep(inClaudeContent content: Any?) -> String? {
        guard let blocks = content as? [[String: Any]] else { return nil }
        var step: String?
        for block in blocks {
            switch block["type"] as? String {
            case "tool_use":
                let input = block["input"] as? [String: Any]
                if let description = input?["description"] as? String, !description.isEmpty {
                    step = trimmed(description)
                } else if let name = block["name"] as? String {
                    step = trimmed(name)
                }
            case "text":
                if let text = block["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    step = trimmed(text)
                }
            default:
                break
            }
        }
        return step
    }

    // MARK: Codex

    private static func readCodex(path: String) -> SessionDetail {
        var detail = SessionDetail()
        for line in lines(atPath: path, window: tailWindow, fromEnd: true) {
            guard let object = json(line),
                  let payload = object["payload"] as? [String: Any] else { continue }

            if object["type"] as? String == "turn_context",
               let model = payload["model"] as? String {
                detail.model = displayName(forModel: model)
            }
            if object["type"] as? String == "event_msg" {
                for key in ["text", "message", "command"] {
                    if let value = payload[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        detail.activity = trimmed(value)
                        break
                    }
                }
            }
        }
        return detail
    }

    // MARK: Shared

    /// A window of complete lines from one end of a file.
    ///
    /// The partial line at the cut is discarded — from the front when reading
    /// the tail, from the back when reading the head — so a half-written record
    /// is never parsed.
    private static func lines(atPath path: String, window: Int, fromEnd: Bool) -> [Substring] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        guard size > 0 else { return [] }
        let length = min(window, size)

        let data: Data?
        if fromEnd {
            try? handle.seek(toOffset: UInt64(size - length))
            data = try? handle.read(upToCount: length)
        } else {
            try? handle.seek(toOffset: 0)
            data = try? handle.read(upToCount: length)
        }
        guard let data, let text = String(data: data, encoding: .utf8) else { return [] }

        var pieces = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !pieces.isEmpty else { return [] }
        // Drop the piece that the window cut in half.
        if fromEnd, length < size { pieces.removeFirst() }
        if !fromEnd, length < size { pieces.removeLast() }
        return pieces
    }

    private static func json(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func trimmed(_ text: String) -> String? {
        let firstLine = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map(String.init) ?? ""
        guard !firstLine.isEmpty else { return nil }
        guard firstLine.count > maxActivityLength else { return firstLine }
        return String(firstLine.prefix(maxActivityLength - 1)) + "…"
    }

    /// "claude-opus-5" → "Opus 5". Unknown identifiers are prettified rather
    /// than shown raw, and never invented: if it cannot be read, it is dropped.
    static func displayName(forModel identifier: String) -> String? {
        let id = identifier.lowercased()
        guard !id.isEmpty, !id.hasPrefix("<") else { return nil }

        var parts = id.split(separator: "-").map(String.init)
        // Vendor prefixes carry no information for the reader.
        if let first = parts.first, ["claude", "anthropic"].contains(first) {
            parts.removeFirst()
        }
        // Trailing date stamps, e.g. haiku-4-5-20251001.
        if let last = parts.last, last.count == 8, Int(last) != nil {
            parts.removeLast()
        }
        guard !parts.isEmpty else { return nil }

        // Version segments join with a dot: 4, 5 → "4.5". A lone number stays.
        var name = parts.removeFirst()
        name = name == "gpt" ? "GPT" : name.capitalized
        let numbers = parts.filter { Int($0) != nil }
        let words = parts.filter { Int($0) == nil }
        var label = name
        if !numbers.isEmpty { label += " " + numbers.joined(separator: ".") }
        if !words.isEmpty { label += " " + words.map(\.capitalized).joined(separator: " ") }
        return label
    }
}

