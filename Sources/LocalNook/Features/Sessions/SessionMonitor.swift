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

    private init() {
        settingsSubscription = Settings.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self, self.running else { return }
                self.rescan()
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
        Task { [weak self] in
            let found = await Self.scan(agents: agents)
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

    /// Collects transcript metadata. Never opens a file.
    nonisolated static func scan(agents: [SessionAgent], roots: [SessionAgent: URL] = [:]) async -> [AgentSession] {
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
                continuation.resume(returning: Array(results.prefix(30)))
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
