//
//  SessionMonitor.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Watches Claude Code and Codex session transcripts so you can see, from the
//  notch, which agents are working and which have gone quiet waiting on you.
//
//  PRIVACY — this is the important part:
//  LocalNook reads **file metadata only**: path, modification date and size. It
//  never opens a transcript, never reads a single line of a conversation, and
//  never sends anything anywhere. Everything below operates on `URLResourceValues`.
//

import Combine
import Foundation

/// Who makes an agent.
///
/// Separate from the agent itself because the badge is about the maker: two
/// Claude sessions are still "Claude", and the generic mark is for a mix.
///
/// The symbols are SF Symbols chosen to *evoke* each maker, not their logos.
/// Shipping a company's actual mark would mean bundling someone else's
/// trademarked artwork in a GPL-3.0 app, which is a licensing question rather
/// than a design one.
nonisolated enum SessionProvider: String, CaseIterable, Equatable, Sendable {
    case anthropic
    case openAI

    var label: String {
        switch self {
        case .anthropic: "Claude"
        case .openAI: "OpenAI"
        }
    }

    var symbol: String {
        switch self {
        case .anthropic: "asterisk"
        case .openAI: "circle.hexagonpath"
        }
    }

    /// Shown when sessions from more than one maker are running at once.
    static let mixedSymbol = "brain.head.profile"
}

/// Pure value type with no shared state, so it is safe off the main actor —
/// the background scan needs `rootDirectory`.
nonisolated enum SessionAgent: String, CaseIterable, Identifiable {
    case claudeCode
    case codex
    /// Chats in the ChatGPT desktop app. They run in OpenAI's cloud and leave
    /// no transcript here; what LocalNook sees is the app's own local list of
    /// them. See ChatGPTCatalogReader.
    case chatGPT

    var id: String { rawValue }

    /// Whether this agent leaves a transcript on disk. The ChatGPT source does
    /// not, so it never takes a transcript-reading slot, never counts toward
    /// transcript volume, and is never read by SessionDetailReader.
    var hasTranscript: Bool { self != .chatGPT }

    var label: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .chatGPT: "ChatGPT"
        }
    }

    var symbol: String {
        switch self {
        case .claudeCode: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .chatGPT: "bubble.left.and.bubble.right"
        }
    }

    var provider: SessionProvider {
        switch self {
        case .claudeCode: .anthropic
        case .codex: .openAI
        case .chatGPT: .openAI
        }
    }

    var rootDirectory: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return switch self {
        case .claudeCode: home.appendingPathComponent(".claude/projects", isDirectory: true)
        case .codex: home.appendingPathComponent(".codex/sessions", isDirectory: true)
        // Not a folder of transcripts; read through ChatGPTCatalogReader.
        case .chatGPT: nil
        }
    }
}

/// One transcript file, described purely by its metadata.
///
/// `nonisolated` because the scan runs off the main actor and the aggregates in
/// SessionStats are computed there, on the full result set, before the display
/// cap is applied.
nonisolated struct AgentSession: Identifiable, Equatable, Sendable {
    let id: String
    let agent: SessionAgent
    let projectName: String
    let lastActivity: Date
    let byteSize: Int
    /// Model, effort, chat name and current step, read from the transcript.
    /// Empty when the format is not recognised, in which case everything falls
    /// back to the metadata-only presentation. See SessionDetail.
    var detail: SessionDetail = SessionDetail()

    /// What to call this session. The name you gave the chat if there is one,
    /// otherwise the directory, which is often a workspace hash.
    var displayName: String { detail.title ?? projectName }

    /// Anything touched in the last 90 seconds counts as live.
    var isActive: Bool { Date().timeIntervalSince(lastActivity) < 90 }

    /// Live but quiet for a while — usually means it is waiting on you.
    var isIdle: Bool {
        let age = Date().timeIntervalSince(lastActivity)
        return age >= 90 && age < 15 * 60
    }

    var relativeActivity: String {
        let seconds = Int(Date().timeIntervalSince(lastActivity))
        return switch seconds {
        case ..<10: "just now"
        case ..<60: "\(seconds)s ago"
        case ..<3600: "\(seconds / 60)m ago"
        case ..<86400: "\(seconds / 3600)h ago"
        default: "\(seconds / 86400)d ago"
        }
    }
}

/// Lets a scan already reading transcripts be told to stop.
///
/// Discarding a scan's *result* is not the same as stopping its *reads*. The
/// ledger streams whole transcripts, so without this, switching labels off
/// left a background read working through someone's conversations for as long
/// as it took to finish — the answer thrown away, the reading done anyway.
nonisolated final class ScanToken: @unchecked Sendable {
    private var cancelled = false
    private let lock = NSLock()

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// What one scan produced: the sessions worth showing, and counts over every
/// transcript found.
nonisolated struct SessionScan: Sendable {
    var sessions: [AgentSession] = []
    var stats = SessionStats()
    /// How reading the ChatGPT chat list went, when it was watched.
    var chatGPT: ChatGPTCatalogReader.Status?
}

/// Tracks agent sessions by watching their transcript directories.
///
/// Uses `DispatchSource` file-system events rather than a polling timer, so an
/// idle machine does no work at all. A short coalescing delay stops a burst of
/// writes from causing a rescan per line.
final class SessionMonitor: ObservableObject {
    static let shared = SessionMonitor()

    @Published private(set) var sessions: [AgentSession] = []
    /// Counts across every transcript the scan found, not just the ones kept
    /// for display. See SessionStats for what they do and do not mean.
    @Published private(set) var stats = SessionStats()
    /// Shown in Settings, so a change in the ChatGPT app's format is visible
    /// as a sentence rather than as chats quietly vanishing.
    @Published private(set) var chatGPTStatus: ChatGPTCatalogReader.Status?
    @Published private(set) var isWatching = false

    private var watchers: [SessionAgent: DirectoryWatcher] = [:]
    private var rescanTask: Task<Void, Never>?
    /// Sessions that were active last scan, so we can spot one going quiet.
    private var previouslyActive: Set<String> = []
    private var refreshTicker: AnyCancellable?
    private var scanGeneration = 0
    /// The scan currently reading, so it can be stopped rather than ignored.
    private var currentScan: ScanToken?
    private var running = false
    private var settingsSubscription: AnyCancellable?

    /// Labels read from transcripts, held only in memory. See SessionDetailCache.
    private let detailCache = SessionDetailCache()
    /// Running token totals, likewise in memory only. See SessionTokenLedger.
    private let tokenLedger = SessionTokenLedger()

    private init() {
        settingsSubscription = Settings.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                // Switching the feature off must not leave labels sitting in
                // memory, or on screen, that were read under the old setting.
                if Settings.shared.sessionLabelDepth == .metadataOnly {
                    self.forgetTranscriptLabels()
                }
                guard self.running else { return }
                self.rescan()
            }
    }

    /// Drops every label read from a transcript, from the cache and from the
    /// sessions already on screen.
    func forgetTranscriptLabels() {
        // Stop first, then forget. A read still in flight would otherwise
        // finish and refill what was just cleared.
        currentScan?.cancel()
        currentScan = nil
        detailCache.clear()
        // A token total is derived from the same transcripts under the same
        // consent, so it goes when the labels do.
        tokenLedger.clear()
        guard sessions.contains(where: { !$0.detail.wasNotRead }) else { return }
        sessions = sessions.map { session in
            var copy = session
            copy.detail = SessionDetail()
            return copy
        }
    }

    /// Used only by `--render-preview`, to stage sessions for a screenshot.
    ///
    /// Guarded on the same flag that stops `start()` pointing at the user's
    /// real transcript folders, so this cannot put invented sessions in front
    /// of someone running the app for real.
    func previewInject(_ sessions: [AgentSession], stats: SessionStats) {
        guard AppInfo.forbidsTranscriptReads else { return }
        self.sessions = sessions
        self.stats = stats
    }

    var activeSessions: [AgentSession] { sessions.filter(\.isActive) }
    var hasActivity: Bool { !activeSessions.isEmpty }

    private var enabledAgents: [SessionAgent] {
        var agents: [SessionAgent] = []
        if Settings.shared.watchClaudeCode { agents.append(.claudeCode) }
        if Settings.shared.watchCodex { agents.append(.codex) }
        if Settings.shared.watchChatGPT { agents.append(.chatGPT) }
        return agents
    }

    // MARK: Lifecycle

    func start() {
        // The suite and the preview renderer both build real views, and a
        // rendered sessions widget would otherwise point this at the user's
        // actual transcript directories — in the renderer's case writing the
        // result into a PNG on disk. Tests scan fixtures through
        // `scan(agents:roots:)` instead.
        guard !AppInfo.forbidsTranscriptReads else { return }
        stop()
        running = true
        for agent in enabledAgents {
            guard let root = agent.rootDirectory,
                  FileManager.default.fileExists(atPath: root.path) else { continue }
            let watcher = DirectoryWatcher(url: root) { [weak self] in
                // Fires on a background queue — hop to the main actor.
                Task { @MainActor in self?.scheduleRescan() }
            }
            if watcher.start() { watchers[agent] = watcher }
        }
        isWatching = !watchers.isEmpty

        // Directory vnode events are not recursive. A 20-second metadata-only
        // reconciliation catches nested writes, newly created roots and aging sessions.
        refreshTicker = Timer.publish(every: 20, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.rescan() }

        rescan()
    }

    func stop() {
        running = false
        scanGeneration += 1
        watchers.values.forEach { $0.stop() }
        watchers.removeAll()
        refreshTicker?.cancel()
        refreshTicker = nil
        rescanTask?.cancel()
        isWatching = false
    }

    func restart() { start() }

    private func scheduleRescan() {
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.rescan()
        }
    }

    // MARK: Scanning

    func rescan() {
        guard running else { return }
        let agents = enabledAgents
        scanGeneration += 1
        let generation = scanGeneration
        // Reading transcript content needs an explicit choice, and stops at the
        // lock screen — there is nothing to label for a display nobody can see,
        // and a label read now could be shown later on a locked screen.
        let depth: SessionLabelDepth = (ScreenLock.isLocked || AppInfo.forbidsTranscriptReads)
            ? .metadataOnly
            : Settings.shared.sessionLabelDepth
        let cache = detailCache
        let ledger = tokenLedger
        currentScan?.cancel()
        let token = ScanToken()
        currentScan = token
        Task { [weak self] in
            let scan = await Self.scan(agents: agents, depth: depth,
                                       cache: cache, ledger: ledger, token: token)
            guard let self, self.running, self.scanGeneration == generation,
                  !token.isCancelled else { return }
            let found = scan.sessions
            let previous = self.previouslyActive
            self.sessions = found
            self.stats = scan.stats
            self.chatGPTStatus = scan.chatGPT

            // Chats are left out of "went quiet": a chat is always waiting on
            // you once a reply lands, so every reply would become a notification.
            let nowActive = Set(found.filter { $0.isActive && $0.agent.hasTranscript }.map(\.id))
            // A session that was working and has now gone quiet is the moment
            // worth telling you about.
            if Settings.shared.sessionsNotifyOnIdle {
                for id in previous.subtracting(nowActive) {
                    if let session = found.first(where: { $0.id == id }) {
                        NotificationCenter.default.post(
                            name: .agentSessionWentIdle, object: session
                        )
                    }
                }
            }
            self.previouslyActive = nowActive
        }
    }

    /// How recent a session must be for its transcript to be opened at all.
    ///
    /// This was an hour, on the reasoning that a session quiet for longer is
    /// not one anyone is watching. Rate limits changed that: a five-hour window
    /// keeps running whether or not you have used the agent in the last hour,
    /// and a limits panel that goes blank the moment you stop working is close
    /// to useless. A day is still bounded — at most six transcripts are ever
    /// opened — and nothing stale is presented as current: activity state comes
    /// from the transcript's own timestamps, and every limit reading carries
    /// how old it is.
    nonisolated static let transcriptReadWindow: TimeInterval = 86_400

    /// Which sessions have their transcripts read for labels: the six most
    /// recent *transcript* sessions inside the read window.
    ///
    /// Chats have no transcript and never take one of these slots. Before they
    /// existed, the six were simply the first six in the list; with a busy
    /// ChatGPT week that would have meant Claude and Codex sessions losing
    /// their names and steps to chats that cannot use the slot.
    nonisolated static func transcriptDetailSlots(
        _ sessions: [AgentSession], now: Date = Date()
    ) -> [Int] {
        Array(sessions.indices.filter {
            sessions[$0].agent.hasTranscript
                && now.timeIntervalSince(sessions[$0].lastActivity) < transcriptReadWindow
        }.prefix(6))
    }

    /// Collects transcript metadata, plus a bounded peek inside each recent
    /// transcript for the model and the current step. See SessionDetail for
    /// exactly how much is read and what is kept.
    nonisolated static func scan(
        agents: [SessionAgent],
        roots: [SessionAgent: URL] = [:],
        depth: SessionLabelDepth = .metadataOnly,
        cache: SessionDetailCache? = nil,
        ledger: SessionTokenLedger? = nil,
        token: ScanToken? = nil
    ) async -> SessionScan {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var results: [AgentSession] = []
                let manager = FileManager.default
                let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]

                for agent in agents where agent.hasTranscript {
                    guard let root = roots[agent] ?? agent.rootDirectory else { continue }
                    guard let enumerator = manager.enumerator(
                        at: root,
                        includingPropertiesForKeys: keys,
                        options: [.skipsHiddenFiles]
                    ) else { continue }

                    for case let url as URL in enumerator {
                        guard url.pathExtension == "jsonl" else { continue }
                        guard let values = try? url.resourceValues(forKeys: Set(keys)),
                              values.isRegularFile == true,
                              let modified = values.contentModificationDate
                        else { continue }

                        // Anything untouched for a week is history, not a session.
                        guard Date().timeIntervalSince(modified) < 7 * 86400 else { continue }

                        results.append(AgentSession(
                            id: url.path,
                            agent: agent,
                            projectName: Self.projectName(for: url, agent: agent),
                            lastActivity: modified,
                            byteSize: values.fileSize ?? 0
                        ))
                    }
                }

                results.sort { $0.lastActivity > $1.lastActivity }
                // Tallied before the display cap, so "this week" counts the
                // week rather than the top thirty — and before any chats are
                // added, because the figure means transcripts and a chat is not
                // one.
                let stats = SessionStats.tally(results)

                var catalogStatus: ChatGPTCatalogReader.Status?
                if agents.contains(.chatGPT) {
                    let catalog = ChatGPTCatalogReader.read(
                        database: roots[.chatGPT] ?? ChatGPTCatalogReader.defaultDatabase,
                        depth: depth
                    )
                    catalogStatus = catalog.status
                    results.append(contentsOf: catalog.sessions)
                    results.sort { $0.lastActivity > $1.lastActivity }
                }
                var recent = Array(results.prefix(30))

                // Only the handful that could actually be shown are opened, and
                // only the ones recent enough to be worth describing. Reading
                // thirty transcripts on every scan would be wasteful and would
                // widen the read for sessions nobody is looking at.
                if depth == .richLabels {
                    for index in transcriptDetailSlots(recent) {
                        // Checked before each transcript, so a cancellation
                        // stops at the next file rather than after all six.
                        if token?.isCancelled == true { break }
                        let session = recent[index]
                        // An unchanged file cannot have a newer answer, so it is
                        // not reopened.
                        if let cached = cache?.detail(
                            forPath: session.id, size: session.byteSize,
                            modified: session.lastActivity
                        ) {
                            recent[index].detail = cached
                        } else {
                            let detail = SessionDetailReader.read(
                                path: session.id, agent: session.agent, depth: depth
                            )
                            recent[index].detail = detail
                            cache?.store(detail, forPath: session.id, size: session.byteSize,
                                         modified: session.lastActivity)
                        }

                        // Claude Code writes usage per message and no total, so
                        // its total is accumulated here instead. Kept outside
                        // the label cache because it advances with the file even
                        // when the labels have not changed.
                        if session.agent == .claudeCode,
                           let tokens = ledger?.update(
                               path: session.id, size: session.byteSize,
                               shouldContinue: { token?.isCancelled != true }
                           ) {
                            recent[index].detail.tokens = tokens
                        }
                    }
                }
                continuation.resume(returning: SessionScan(
                    sessions: recent, stats: stats, chatGPT: catalogStatus
                ))
            }
        }
    }

    /// Derives a human-readable project name from the path alone.
    ///
    /// Claude Code encodes the working directory in the folder name with
    /// slashes replaced by dashes; Codex files are grouped by date instead, so
    /// they fall back to their timestamp.
    private nonisolated static func projectName(for url: URL, agent: SessionAgent) -> String {
        switch agent {
        case .claudeCode:
            let encoded = url.deletingLastPathComponent().lastPathComponent
            let decoded = encoded.replacingOccurrences(of: "-", with: "/")
            let last = decoded.split(separator: "/").last.map(String.init) ?? encoded
            return last.isEmpty ? "Claude Code" : last
        case .codex:
            // rollout-2026-09-05T16-27-16-<uuid>.jsonl
            let name = url.deletingPathExtension().lastPathComponent
            let parts = name.split(separator: "-")
            if parts.count >= 4 {
                return "\(parts[1])-\(parts[2])-\(parts[3])"
            }
            return "Codex session"
        case .chatGPT:
            return "ChatGPT chat"
        }
    }
}

/// Watches immediate directory entries. Nested file writes are reconciled by
/// SessionMonitor's low-frequency metadata scan; vnode events are not recursive.
nonisolated final class DirectoryWatcher: @unchecked Sendable {
    private let url: URL
    private let onChange: @Sendable () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    deinit { stop() }

    @discardableResult
    func start() -> Bool {
        stop()
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        let handler = onChange
        source.setEventHandler { handler() }
        source.setCancelHandler { [descriptor] in
            if descriptor >= 0 { close(descriptor) }
        }
        source.resume()
        self.source = source
        return true
    }

    func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
    }
}

extension Notification.Name {
    static let agentSessionWentIdle = Notification.Name("LocalNook.agentSessionWentIdle")
}
