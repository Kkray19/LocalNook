//
//  SessionStats.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Aggregates over agent sessions, for the AI Sessions dashboard.
//
//  Everything here is derived from three pieces of file metadata — path,
//  modification date and size — which is the same boundary SessionMonitor
//  already works inside. Nothing in this file opens a transcript.
//
//  ── What these numbers do and do not mean ───────────────────────────────────
//
//  A transcript's modification date says when it was *last written*, and its
//  size says how much has been written to it in total. Neither is a record of
//  when a session ran. So:
//
//    * `total` counts transcripts touched in the seven-day scan window, not
//      sessions started in it. A conversation resumed today counts once, today.
//    * `totalBytes` is transcript volume, which correlates with how much was
//      said but is not a token count, a cost, or a measure of work done. It is
//      presented as what it is: bytes on disk. Token counts come from
//      SessionUsage, where the agents report them directly.
//
//  These limits are inherent to metadata. Producing a genuine history of when
//  work happened would mean persisting observations — a record of your agent
//  use, on disk, which this app deliberately does not keep.
//

import Foundation

/// Counts across every transcript the scan found — including the ones beyond
/// the display cap, so "this week" is not silently the top thirty.
nonisolated struct SessionStats: Equatable, Sendable {
    var total = 0
    var totalBytes = 0

    var isEmpty: Bool { total == 0 }

    static func tally(_ sessions: [AgentSession]) -> SessionStats {
        var stats = SessionStats()
        for session in sessions {
            stats.total += 1
            stats.totalBytes += session.byteSize
        }
        return stats
    }

    /// Bytes as a short label. Deliberately not `ByteCountFormatter`: this is
    /// asserted by the suite, and a formatter that changes with the locale and
    /// the OS release cannot be.
    static func volumeLabel(bytes: Int) -> String {
        let value = Double(max(0, bytes))
        let kilobyte = 1024.0
        let megabyte = kilobyte * 1024
        let gigabyte = megabyte * 1024
        if value < kilobyte { return "\(Int(value)) B" }
        if value < megabyte { return scaled(value / kilobyte, "KB") }
        if value < gigabyte { return scaled(value / megabyte, "MB") }
        return scaled(value / gigabyte, "GB")
    }

    /// One decimal place below ten, none above: "4.2 MB", "41 MB".
    private static func scaled(_ value: Double, _ suffix: String) -> String {
        value >= 10
            ? "\(Int(value.rounded())) \(suffix)"
            : String(format: "%.1f %@", value, suffix)
    }
}

/// One working folder, and what has been happening in it.
nonisolated struct ProjectTally: Identifiable, Equatable, Sendable {
    var name: String
    var sessions: Int
    var active: Int
    var lastActivity: Date

    var id: String { name }
}

/// Projects, plus how many sessions could not be attributed to one.
///
/// The unattributed count is carried rather than dropped: a Codex session whose
/// working directory has not been read is not "no project", it is "project
/// unknown", and a list that quietly omits it would under-count the week.
nonisolated struct ProjectBreakdown: Equatable, Sendable {
    var projects: [ProjectTally] = []
    var unattributed = 0

    var isEmpty: Bool { projects.isEmpty && unattributed == 0 }

    static func build(
        from sessions: [AgentSession],
        now: Date = Date()
    ) -> ProjectBreakdown {
        var byName: [String: ProjectTally] = [:]
        var unattributed = 0

        for session in sessions {
            // A chat has no working folder. That is not "unknown", it is simply
            // not a project, so it is neither listed nor counted as unattributed.
            guard session.agent.hasTranscript else { continue }
            guard let name = session.projectLabel else {
                unattributed += 1
                continue
            }
            var tally = byName[name] ?? ProjectTally(
                name: name, sessions: 0, active: 0, lastActivity: session.lastActivity
            )
            tally.sessions += 1
            if session.isActive { tally.active += 1 }
            tally.lastActivity = max(tally.lastActivity, session.lastActivity)
            byName[name] = tally
        }

        let sorted = byName.values.sorted {
            if $0.sessions != $1.sessions { return $0.sessions > $1.sessions }
            return $0.lastActivity > $1.lastActivity
        }
        return ProjectBreakdown(projects: sorted, unattributed: unattributed)
    }
}

extension AgentSession {
    /// The working folder this session belongs to, where it is known.
    ///
    /// Claude Code encodes the directory in its transcript path, so it is known
    /// from metadata alone. Codex groups its files by date instead, so its
    /// folder is only known when transcript labels are switched on and the
    /// `cwd` field has been read — absent otherwise, rather than guessed from
    /// the timestamp the path does carry.
    nonisolated var projectLabel: String? {
        switch agent {
        case .claudeCode: projectName
        case .codex: detail.title
        case .chatGPT: nil
        }
    }
}
