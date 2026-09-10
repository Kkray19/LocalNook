//
//  SessionsProbe.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  `LocalNook --sessions-probe`: what the session reader gets out of the real
//  transcripts on this Mac, right now.
//
//  Exists for the same reason MediaProbe does. Fixtures prove the parser
//  handles the shape it was written against; only real files prove that shape
//  is the one the agents are writing this week. The Codex `tab`-versus-`tab`
//  bug and the `turn_context` that fell out of the tail window were both found
//  this way and neither was visible from a test.
//
//  It is also the only route available for checking the dashboard's numbers
//  without a click, and clicking would need an Accessibility grant.
//
//  ── What it prints, and what it will not ───────────────────────────────────
//
//  Numbers, flags and model identifiers. Never a chat name, never a step,
//  never a folder — for those it prints only whether one was found, because
//  "the title was read" is the diagnostic fact and the title itself is the
//  user's content. A probe that spilled either into a terminal scrollback or a
//  bug report would be a worse problem than the one it solves.
//

import Foundation

enum SessionsProbe {
    static func run() -> Never {
        let depth = Settings.shared.sessionLabelDepth
        print("LocalNook sessions probe")
        print("  label depth: \(depth.rawValue)")
        if depth == .metadataOnly {
            print("  (transcript bodies are not read at this setting, so tokens")
            print("   and limits will be absent by design, not by failure)")
        }
        print("")

        let agents = SessionAgent.allCases
        // Timed, because "how long does a scan cost" is exactly the kind of
        // thing this tool exists to answer — the ledger reads whole
        // transcripts, and the cost of that should never be a guess.
        let started = Date()
        var scan: SessionScan?
        Task {
            scan = await SessionMonitor.scan(
                agents: agents, depth: depth, cache: nil,
                ledger: SessionTokenLedger()
            )
        }
        let deadline = Date().addingTimeInterval(20)
        while scan == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard let scan else {
            print("  the scan did not finish within 20s")
            exit(2)
        }

        let scanned = Date().timeIntervalSince(started)
        print("SCAN")
        print(String(format: "  took %.2fs", scanned))
        print("  transcripts in the window: \(scan.stats.total)")
        print("  volume: \(SessionStats.volumeLabel(bytes: scan.stats.totalBytes))")
        print("  listed: \(scan.sessions.count)")
        print("")

        print("SESSIONS  (presence only for anything a person wrote)")
        for session in scan.sessions.prefix(10) {
            let detail = session.detail
            var flags: [String] = []
            flags.append("name=\(detail.title == nil ? "no" : "yes")")
            flags.append("model=\(detail.model ?? "none")")
            flags.append("activity=\(detail.activity.rawValue)")
            flags.append("step=\(detail.step == nil ? "no" : "yes")")
            flags.append("tokens=\(detail.tokens.map { TokenUsage.short($0.fresh) } ?? "none")")
            flags.append("limits=\(detail.limits.count)")
            print("  \(session.agent.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0))"
                  + "\(Int(Date().timeIntervalSince(session.lastActivity)))s ago  "
                  + flags.joined(separator: "  "))
        }
        print("")

        let usage = UsageSummary.build(from: scan.sessions)
        print("TOKENS BY MODEL")
        if usage.models.isEmpty { print("  none reported") }
        for entry in usage.models {
            let tokens = entry.tokensUnreported
                ? "not reported"
                : "\(TokenUsage.short(entry.tokens.fresh)) fresh, "
                    + "\(TokenUsage.short(entry.tokens.output)) out, "
                    + "\(TokenUsage.short(entry.tokens.cachedInput)) cached"
            print("  \(entry.provider.rawValue)/\(entry.model ?? "model not recorded"): "
                  + "\(entry.sessions) session(s), \(tokens)")
        }
        print("")

        print("LIMITS")
        if usage.limits.isEmpty { print("  none published by any agent here") }
        for window in usage.limits {
            let reset = window.resetText().map { "resets in \($0)" } ?? "window has reset"
            let age = window.ageText().map { "read \($0)" } ?? "read just now"
            print("  \(window.provider.rawValue) \(window.label): "
                  + "\(Int(window.usedPercent.rounded()))%  \(reset)  \(age)"
                  + (window.hasExpired() ? "  EXPIRED" : ""))
        }
        for provider in usage.providersWithoutLimits {
            print("  \(provider.rawValue): publishes none on this Mac")
        }

        print("")
        let beforeApps = Date()
        print("APPS")
        for provider in SessionProvider.allCases {
            print("  \(provider.rawValue): "
                  + (AgentApplication.displayName(for: provider) ?? "not installed"))
        }
        print(String(format: "  resolved in %.2fs", Date().timeIntervalSince(beforeApps)))
        print(String(format: "\ntotal %.2fs", Date().timeIntervalSince(started)))
        exit(0)
    }
}
