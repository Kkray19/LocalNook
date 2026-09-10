//
//  SessionUsage.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Token counts and rate-limit windows, as the agents themselves record them.
//
//  ── Where these numbers come from, and where they do not ───────────────────
//
//  LocalNook makes no network requests. Nothing here is fetched from an API,
//  and nothing is estimated: every value is a number an agent wrote into its
//  own transcript on this Mac. That has an uneven consequence worth stating
//  plainly rather than papering over, because the gap is visible in the UI:
//
//    * **Codex records both.** Every `token_count` event carries the session's
//      running token total and a snapshot of the account's rate limits — a
//      primary window (300 minutes) and a secondary one (10080 minutes, a
//      week), each with a percentage used and the instant it resets.
//    * **Claude Code records neither.** Its transcripts carry per-message
//      usage, but no running total, and no rate-limit state is written
//      anywhere under `~/.claude`. A session total could only be had by
//      summing every message in the file — 88 MB for the transcript that
//      prompted this — which is neither cheap enough for a widget nor a
//      reasonable widening of what gets read. So Claude models appear with
//      their session counts and no token figure, and the limits panel says
//      the limits are not published rather than drawing an empty bar.
//
//  A limit is a *snapshot*, not a live reading. It was true when the agent
//  wrote it, and an agent that stopped an hour ago left an hour-old number.
//  Every snapshot therefore carries when it was observed, the UI shows that
//  age, and a reading whose window has since reset is marked as expired
//  instead of being shown as though it still described the current window.
//

import Foundation

/// Tokens for one session or one model.
///
/// ── Why the headline is not the sum of everything ──────────────────────────
///
/// Both agents report tokens per request, and both re-count the whole prompt
/// on every request. With prompt caching that means the *same* context is
/// counted again on every turn: one Claude session on this Mac sums to 2.48
/// **billion** tokens across 4,888 turns, of which 2.45 billion are the same
/// conversation being read back out of cache. That number is a true sum and a
/// useless measure of use — it grows with how long a conversation is, not with
/// how much work was done.
///
/// So `fresh` is the headline: input the model had not already been given,
/// plus what it wrote. `cachedInput` is kept beside it rather than folded in,
/// and `processed` is available for anyone who wants the raw sum.
///
/// The two agents describe this differently and are normalised here rather
/// than at the call sites:
///
///   * Codex's `input_tokens` **includes** its `cached_input_tokens`, so fresh
///     input is the difference.
///   * Claude's `input_tokens` **excludes** cache, and cache *writes* are
///     charged as fresh input, so fresh input is `input_tokens` plus
///     `cache_creation_input_tokens`.
nonisolated struct TokenUsage: Equatable, Sendable {
    /// Input the model actually had to read, cache writes included.
    var freshInput = 0
    /// Input served from cache. Re-counted every turn, so it is reported
    /// separately and never added into the headline.
    var cachedInput = 0
    var output = 0
    var reasoning = 0

    /// What this session actually consumed.
    var fresh: Int { freshInput + output }
    /// Every token the model was handed, cache reads included. The big number.
    var processed: Int { freshInput + cachedInput + output }

    var isEmpty: Bool { freshInput == 0 && cachedInput == 0 && output == 0 }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            freshInput: lhs.freshInput + rhs.freshInput,
            cachedInput: lhs.cachedInput + rhs.cachedInput,
            output: lhs.output + rhs.output,
            reasoning: lhs.reasoning + rhs.reasoning
        )
    }

    /// "18.5M", "812K", "940". Written out rather than taken from a formatter
    /// so the suite can assert it and so it does not shift with the locale.
    static func short(_ count: Int) -> String {
        let value = Double(max(0, count))
        if value < 1000 { return "\(Int(value))" }
        if value < 1_000_000 { return scaled(value / 1000, "K") }
        if value < 1_000_000_000 { return scaled(value / 1_000_000, "M") }
        return scaled(value / 1_000_000_000, "B")
    }

    private static func scaled(_ value: Double, _ suffix: String) -> String {
        value >= 100
            ? "\(Int(value.rounded()))\(suffix)"
            : String(format: "%.1f%@", value, suffix)
    }
}

/// One rate-limit window as an agent last saw it.
nonisolated struct RateLimitWindow: Equatable, Sendable, Identifiable {
    var provider: SessionProvider
    /// 300 for the five-hour window, 10080 for the week.
    var windowMinutes: Int
    var usedPercent: Double
    var resetsAt: Date
    /// When the transcript recorded this. The number is only as fresh as this.
    var observedAt: Date

    var id: String { "\(provider.rawValue).\(windowMinutes)" }

    /// "5h", "Week", or the window's own length when it is neither.
    var label: String {
        switch windowMinutes {
        case 300: "5h"
        case 10080: "Week"
        case ..<1440: "\(max(1, windowMinutes / 60))h"
        default: "\(windowMinutes / 1440)d"
        }
    }

    /// The window this reading describes has already rolled over, so the
    /// percentage belongs to a period that has ended.
    func hasExpired(now: Date = Date()) -> Bool { now >= resetsAt }

    /// How long until it resets, or nil once it has.
    func resetText(now: Date = Date()) -> String? {
        let seconds = Int(resetsAt.timeIntervalSince(now))
        guard seconds > 0 else { return nil }
        if seconds < 3600 { return "\(max(1, seconds / 60))m" }
        if seconds < 86400 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        return "\(seconds / 86400)d \((seconds % 86400) / 3600)h"
    }

    /// How old the reading is, when that is old enough to matter.
    ///
    /// A percentage is a fact about the moment it was written. Two minutes is
    /// the same window LocalNook uses everywhere else to call a session live.
    func ageText(now: Date = Date()) -> String? {
        let seconds = Int(now.timeIntervalSince(observedAt))
        guard seconds >= 120 else { return nil }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}

/// Tokens attributed to one model.
nonisolated struct ModelUsage: Equatable, Sendable, Identifiable {
    /// Absent when the session reported tokens but no model.
    ///
    /// This is not hypothetical: a long Codex session pushes its
    /// `turn_context` — the only record naming the model — past the tail
    /// window, and it has no head fallback because a model taken from the
    /// start of a session may not be the one running now. Those tokens are
    /// real and are kept under an entry that says the model is unknown, rather
    /// than being dropped from the table or filed under a guess.
    var model: String?
    var provider: SessionProvider
    var sessions: Int
    var tokens: TokenUsage
    /// True when no session for this model reported a total. Distinct from a
    /// total of zero, and shown as "not reported" rather than "0".
    var tokensUnreported: Bool

    var id: String { "\(provider.rawValue).\(model ?? "unknown")" }
}

/// Everything the usage side of the dashboard needs, computed in one pass.
nonisolated struct UsageSummary: Equatable, Sendable {
    var models: [ModelUsage] = []
    var limits: [RateLimitWindow] = []
    /// Makers whose sessions are on screen but which publish no limits here.
    /// Carried so the panel can say so, rather than looking empty.
    var providersWithoutLimits: [SessionProvider] = []

    var isEmpty: Bool { models.isEmpty && limits.isEmpty }

    static func build(from sessions: [AgentSession]) -> UsageSummary {
        var byModel: [String: ModelUsage] = [:]
        var newest: [String: RateLimitWindow] = [:]
        var providers: Set<SessionProvider> = []
        var providersWithLimits: Set<SessionProvider> = []

        for session in sessions {
            // Only agents that could publish limits count here. A ChatGPT chat
            // never carries them, so it must not make OpenAI read as "publishes
            // no limits" when Codex does.
            if session.agent.hasTranscript { providers.insert(session.agent.provider) }

            // A limit is account-wide, so several sessions describe the same
            // window. The most recently observed snapshot wins — an older one
            // is not an independent reading, it is the same number staler.
            for window in session.detail.limits {
                providersWithLimits.insert(window.provider)
                if let existing = newest[window.id], existing.observedAt >= window.observedAt {
                    continue
                }
                newest[window.id] = window
            }

            let model = session.detail.model
            // A session with neither a model nor tokens has nothing to add to
            // this table; one with tokens and no model has a real figure that
            // must not be lost with it.
            guard model != nil || session.detail.tokens != nil else { continue }
            let key = "\(session.agent.provider.rawValue).\(model ?? "")"
            var entry = byModel[key] ?? ModelUsage(
                model: model, provider: session.agent.provider,
                sessions: 0, tokens: TokenUsage(), tokensUnreported: true
            )
            entry.sessions += 1
            if let tokens = session.detail.tokens {
                entry.tokens = entry.tokens + tokens
                entry.tokensUnreported = false
            }
            byModel[key] = entry
        }

        let models = byModel.values.sorted {
            // Models that report tokens rank by them; the rest fall in behind,
            // by how many sessions used them. A named model outranks an
            // unnamed one at equal standing, so the table leads with what can
            // actually be read.
            if $0.tokensUnreported != $1.tokensUnreported { return !$0.tokensUnreported }
            if ($0.model == nil) != ($1.model == nil) { return $0.model != nil }
            if $0.tokensUnreported { return $0.sessions > $1.sessions }
            return $0.tokens.fresh > $1.tokens.fresh
        }
        let limits = newest.values.sorted {
            if $0.provider != $1.provider { return $0.provider.rawValue < $1.provider.rawValue }
            return $0.windowMinutes < $1.windowMinutes
        }
        return UsageSummary(
            models: models,
            limits: limits,
            providersWithoutLimits: providers.subtracting(providersWithLimits)
                .sorted { $0.rawValue < $1.rawValue }
        )
    }
}
