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

/// Pure value type with no shared state, so it is safe off the main actor —
/// the background scan needs `rootDirectory`.
nonisolated enum SessionAgent: String, CaseIterable, Identifiable {
    case claudeCode
    case codex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    var symbol: String {
        switch self {
        case .claudeCode: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }

    var rootDirectory: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return switch self {
        case .claudeCode: home.appendingPathComponent(".claude/projects", isDirectory: true)
        case .codex: home.appendingPathComponent(".codex/sessions", isDirectory: true)
        }
    }
}

/// One transcript file, described purely by its metadata.
struct AgentSession: Identifiable, Equatable, Sendable {
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

/// Tracks agent sessions by watching their transcript directories.
///
/// Uses `DispatchSource` file-system events rather than a polling timer, so an
/// idle machine does no work at all. A short coalescing delay stops a burst of
/// writes from causing a rescan per line.
final class SessionMonitor: ObservableObject {
    static let shared = SessionMonitor()

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var isWatching = false

    private var watchers: [SessionAgent: DirectoryWatcher] = [:]
    private var rescanTask: Task<Void, Never>?
    /// Sessions that were active last scan, so we can spot one going quiet.
    private var previouslyActive: Set<String> = []
    private var refreshTicker: AnyCancellable?
    private var scanGeneration = 0
    private var running = false
    private var settingsSubscription: AnyCancellable?

    /// Labels read from transcripts, held only in memory. See SessionDetailCache.
    private let detailCache = SessionDetailCache()

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
        detailCache.clear()
        guard sessions.contains(where: { !$0.detail.wasNotRead }) else { return }
        sessions = sessions.map { session in
            var copy = session
            copy.detail = SessionDetail()
            return copy
        }
    }

    var activeSessions: [AgentSession] { sessions.filter(\.isActive) }
    var hasActivity: Bool { !activeSessions.isEmpty }

    private var enabledAgents: [SessionAgent] {
        var agents: [SessionAgent] = []
        if Settings.shared.watchClaudeCode { agents.append(.claudeCode) }
        if Settings.shared.watchCodex { agents.append(.codex) }
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
        Task { [weak self] in
            let found = await Self.scan(agents: agents, depth: depth, cache: cache)
            guard let self, self.running, self.scanGeneration == generation else { return }
            let previous = self.previouslyActive
            self.sessions = found

            let nowActive = Set(found.filter(\.isActive).map(\.id))
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

    /// Collects transcript metadata, plus a bounded peek inside each recent
    /// transcript for the model and the current step. See SessionDetail for
    /// exactly how much is read and what is kept.
    nonisolated static func scan(
        agents: [SessionAgent],
        roots: [SessionAgent: URL] = [:],
        depth: SessionLabelDepth = .metadataOnly,
        cache: SessionDetailCache? = nil
    ) async -> [AgentSession] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var results: [AgentSession] = []
                let manager = FileManager.default
                let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]

                for agent in agents {
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
                var recent = Array(results.prefix(30))

                // Only the handful that could actually be shown are opened, and
                // only the ones recent enough to be worth describing. Reading
                // thirty transcripts on every scan would be wasteful and would
                // widen the read for sessions nobody is looking at.
                // Only the few that could actually be shown are opened, and only
                // those recent enough to be worth describing. Reading thirty
                // transcripts every scan would be wasteful and would widen the
                // read to sessions nobody is looking at.
                if depth == .richLabels {
                    for index in recent.indices.prefix(6)
                    where Date().timeIntervalSince(recent[index].lastActivity) < 3600 {
                        let session = recent[index]
                        // An unchanged file cannot have a newer answer, so it is
                        // not reopened.
                        if let cached = cache?.detail(
                            forPath: session.id, size: session.byteSize,
                            modified: session.lastActivity
                        ) {
                            recent[index].detail = cached
                            continue
                        }
                        let detail = SessionDetailReader.read(
                            path: session.id, agent: session.agent, depth: depth
                        )
                        recent[index].detail = detail
                        cache?.store(detail, forPath: session.id, size: session.byteSize,
                                     modified: session.lastActivity)
                    }
                }
                continuation.resume(returning: recent)
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
