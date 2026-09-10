//
//  SessionTokenLedger.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Running token totals for Claude Code sessions, which record per-message
//  usage and no total of their own.
//
//  ── This reads whole transcripts, and that is a real widening ──────────────
//
//  Everything else in LocalNook samples: SessionDetail takes a 256 KB tail and
//  a 512 KB head and states plainly that a label outside those windows is
//  missed. A running total cannot be sampled. A sum over part of a file is not
//  a smaller total, it is a wrong one, and a widget showing a wrong total with
//  no way to tell is worse than one showing none.
//
//  So this streams the whole file — 94 MB for the largest transcript on this
//  Mac — and that is a deliberate change to the boundary rather than an
//  oversight. What limits it:
//
//    * **Only integers leave.** Four numbers per record, out of one named
//      object. No text is retained, compared, or logged; the parsed record is
//      discarded before the next line is read. A byte being read is not the
//      same as a byte being kept, and nothing here keeps one.
//    * **Same consent, same locks.** It runs only under `richLabels`, only
//      when the screen is unlocked, and only for the handful of recent
//      sessions the scan already opens. Switching labels off drops the ledger
//      whole, exactly as it drops the label cache.
//    * **Once per file, then only the new bytes.** Each transcript is read
//      through once; after that the ledger seeks to where it stopped and reads
//      only what has been appended. A conversation that grows by a few
//      kilobytes costs a few kilobytes.
//    * **In memory only.** Never written to disk, never logged. The totals die
//      with the process.
//
//  Measured, on the 90 MB transcript that prompted this and the five smaller
//  ones beside it: a cold pass over all six costs about two seconds on a
//  utility queue, once, and every scan after that costs only the bytes that
//  have been appended. Most of those two seconds is `JSONSerialization`
//  parsing whole assistant records.
//
//  It could be made faster by locating the `usage` object and parsing only
//  that, and it deliberately is not: `"usage":{` can appear in a record's text
//  as easily as in its fields, so a sub-parser would trade a one-off second at
//  launch for a chance of a confidently wrong total. Nothing here is worth
//  that trade.
//

import Foundation

/// Streams a Claude Code transcript and adds up what it reports using.
nonisolated enum SessionTokenReader {
    /// Read in chunks rather than whole: a 94 MB `Data` is not something to
    /// hold for a widget, and lines are processed and dropped as they arrive.
    static let chunkSize = 1 << 20

    /// A line that cannot contain a usage record is never parsed. Most of a
    /// transcript is user turns, attachments and tool output; only assistant
    /// records carry `usage`, and skipping the rest on a substring test is
    /// what makes a full pass cheap.
    private static let markerBytes = Array(#""type":"assistant""#.utf8)

    /// Adds everything from `offset` onwards into `usage`.
    ///
    /// Returns where to resume: the start of the trailing line, if the file
    /// ended mid-record. Stopping at the last newline is what keeps a record
    /// that is still being written from being counted as a short one now and
    /// skipped when it is complete.
    ///
    /// Scanning is done with `memchr` and `memmem` rather than Foundation's
    /// `Data.firstIndex(of:)` and `range(of:)`. That is not premature: the
    /// first version used them and a single pass over the 90 MB transcript on
    /// this Mac took 4.2 seconds, against 0.03 for `cat`. Searching every line
    /// for the marker was quadratic in all but name.
    static func accumulate(
        path: String, from offset: UInt64, into usage: inout TokenUsage
    ) -> UInt64 {
        guard let handle = FileHandle(forReadingAtPath: path) else { return offset }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil else { return offset }

        var consumed = offset
        var carry: [UInt8] = []

        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            var buffer = carry
            buffer.append(contentsOf: chunk)
            carry = []

            var start = 0
            while let newline = Self.index(ofByte: UInt8(ascii: "\n"), in: buffer, from: start) {
                add(line: buffer[start..<newline], to: &usage)
                consumed += UInt64(newline - start + 1)
                start = newline + 1
            }
            // Whatever is left has no newline yet: either the chunk boundary
            // split a record, or the file ends mid-write.
            carry = Array(buffer[start...])
        }
        return consumed
    }

    private static func index(ofByte byte: UInt8, in buffer: [UInt8], from start: Int) -> Int? {
        guard start < buffer.count else { return nil }
        return buffer.withUnsafeBytes { raw -> Int? in
            guard let base = raw.baseAddress else { return nil }
            guard let hit = memchr(base + start, Int32(byte), raw.count - start) else { return nil }
            return UnsafeRawPointer(hit) - base
        }
    }

    private static func contains(_ needle: [UInt8], in line: ArraySlice<UInt8>) -> Bool {
        guard line.count >= needle.count else { return false }
        return line.withUnsafeBytes { haystack in
            needle.withUnsafeBytes { pattern in
                guard let h = haystack.baseAddress, let p = pattern.baseAddress else { return false }
                return memmem(h, haystack.count, p, pattern.count) != nil
            }
        }
    }

    private static func add(line: ArraySlice<UInt8>, to usage: inout TokenUsage) {
        guard contains(markerBytes, in: line) else { return }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let raw = message["usage"] as? [String: Any]
        else { return }
        usage = usage + claudeUsage(from: raw)
    }

    /// One assistant record's usage.
    ///
    /// Deliberately reads the top-level object only. The same numbers appear
    /// again inside `usage.iterations`, and adding both would double every
    /// figure — which would look plausible and be wrong by exactly 2×.
    static func claudeUsage(from raw: [String: Any]) -> TokenUsage {
        func number(_ key: String, in object: [String: Any]) -> Int {
            if let value = object[key] as? Int { return max(0, value) }
            if let value = object[key] as? Double, value.isFinite { return max(0, Int(value)) }
            return 0
        }
        // Cache *writes* are input the model had to read, so they are fresh.
        // Cache *reads* are the same context handed back, so they are not.
        let fresh = number("input_tokens", in: raw)
            + number("cache_creation_input_tokens", in: raw)
        let details = raw["output_tokens_details"] as? [String: Any] ?? [:]
        return TokenUsage(
            freshInput: fresh,
            cachedInput: number("cache_read_input_tokens", in: raw),
            output: number("output_tokens", in: raw),
            reasoning: number("thinking_tokens", in: details)
        )
    }
}

/// Remembers how far each transcript has been summed, so a growing file costs
/// only what was added to it.
///
/// In memory only, for the same reason SessionDetailCache is: a total is
/// derived from someone's conversations, and writing it to disk would outlive
/// the permission that produced it. Dropped whole when labels are switched off.
nonisolated final class SessionTokenLedger: @unchecked Sendable {
    private struct Entry {
        var offset: UInt64
        var usage: TokenUsage
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    /// Brings `path` up to date and returns its total.
    ///
    /// A file that has *shrunk* since last time is not the same file — a
    /// transcript rotated, replaced or truncated — so its total is discarded
    /// and rebuilt rather than being added to and quietly wrong.
    func update(path: String, size: Int) -> TokenUsage? {
        lock.lock()
        var entry = entries[path] ?? Entry(offset: 0, usage: TokenUsage())
        if UInt64(max(0, size)) < entry.offset {
            entry = Entry(offset: 0, usage: TokenUsage())
        }
        lock.unlock()

        guard UInt64(max(0, size)) > entry.offset || entry.offset == 0 else {
            return entry.usage.isEmpty ? nil : entry.usage
        }

        var usage = entry.usage
        let offset = SessionTokenReader.accumulate(
            path: path, from: entry.offset, into: &usage
        )

        lock.lock()
        // Bounded for the same reason the label cache is: only a handful of
        // sessions are ever read, and an unbounded map here would hold a total
        // for every transcript the machine has ever had.
        if entries.count > 64 { entries.removeAll() }
        entries[path] = Entry(offset: offset, usage: usage)
        lock.unlock()

        return usage.isEmpty ? nil : usage
    }

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
