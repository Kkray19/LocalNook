//
//  ShortcutsManager.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Lists and runs macOS Shortcuts through the system `shortcuts` CLI.
//
//  Safety note: every invocation uses `Process.arguments`, which passes the
//  shortcut name to the binary as a single argv entry. No shell is involved
//  anywhere, so a shortcut named `; rm -rf ~` is just a name.
//
//  LocalNook only ever *lists* and *runs* shortcuts. It never creates, edits or
//  deletes them.
//

import AppKit
import Combine
import Foundation

struct ShortcutEntry: Identifiable, Hashable {
    var id: String { name }
    let name: String
}

final class ShortcutsManager: ObservableObject {
    static let shared = ShortcutsManager()

    @Published private(set) var shortcuts: [ShortcutEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var runningNames: Set<String> = []
    @Published private(set) var lastError: String?
    @Published private(set) var hasLoadedOnce = false

    private static let executable = "/usr/bin/shortcuts"

    private init() {}

    var isSupported: Bool {
        FileManager.default.isExecutableFile(atPath: Self.executable)
    }

    var pinned: [ShortcutEntry] {
        let names = Set(Settings.shared.pinnedShortcutNames)
        return shortcuts.filter { names.contains($0.name) }
    }

    func isPinned(_ entry: ShortcutEntry) -> Bool {
        Settings.shared.pinnedShortcutNames.contains(entry.name)
    }

    func togglePin(_ entry: ShortcutEntry) {
        var names = Settings.shared.pinnedShortcutNames
        if let index = names.firstIndex(of: entry.name) {
            names.remove(at: index)
        } else {
            names.append(entry.name)
        }
        Settings.shared.pinnedShortcutNames = names
        objectWillChange.send()
    }

    /// Reads the shortcut list. Cheap enough to call when the widget appears,
    /// but never on a timer.
    func reload() {
        guard isSupported, !isLoading else { return }
        isLoading = true
        lastError = nil

        Task { [weak self] in
            let result = await ProcessRunner.run(Self.executable, ["list"])
            guard let self else { return }
            self.isLoading = false
            self.hasLoadedOnce = true

            guard result.exitCode == 0 else {
                self.lastError = result.standardError.isEmpty
                    ? "Could not read your shortcuts."
                    : result.standardError
                return
            }
            self.shortcuts = result.standardOutput
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map(ShortcutEntry.init)
        }
    }

    func run(_ entry: ShortcutEntry) {
        guard isSupported, !runningNames.contains(entry.name) else { return }
        runningNames.insert(entry.name)
        lastError = nil

        Task { [weak self] in
            // Name is passed as its own argv entry — never interpolated.
            let result = await ProcessRunner.run(Self.executable, ["run", entry.name])
            guard let self else { return }
            self.runningNames.remove(entry.name)
            if result.exitCode != 0 {
                self.lastError = result.standardError.isEmpty
                    ? "\(entry.name) did not finish successfully."
                    : result.standardError
            }
        }
    }

    /// Opens the shortcut for editing in the Shortcuts app.
    func edit(_ entry: ShortcutEntry) {
        guard let encoded = entry.name.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ), let url = URL(string: "shortcuts://open-shortcut?name=\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Minimal async wrapper around `Process`.
///
/// Always takes an explicit executable path and an argument array — there is no
/// code path here that builds a command string, so shell injection is not
/// possible by construction.
enum ProcessRunner {
    struct Result: Sendable {
        let exitCode: Int32
        let standardOutput: String
        let standardError: String
    }

    static func run(_ executable: String, _ arguments: [String], timeout: Duration = .seconds(30)) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments

                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let outURL = directory.appendingPathComponent("stdout")
                    let errURL = directory.appendingPathComponent("stderr")
                    FileManager.default.createFile(atPath: outURL.path, contents: nil)
                    FileManager.default.createFile(atPath: errURL.path, contents: nil)
                    let output = try FileHandle(forWritingTo: outURL)
                    let errors = try FileHandle(forWritingTo: errURL)
                    defer { try? output.close(); try? errors.close() }
                    process.standardOutput = output
                    process.standardError = errors
                    process.standardInput = FileHandle.nullDevice
                    let finished = DispatchSemaphore(value: 0)
                    process.terminationHandler = { _ in finished.signal() }
                    try process.run()
                    let parts = timeout.components
                    let seconds = max(0, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
                    let timedOut = finished.wait(timeout: .now() + seconds) == .timedOut
                    if timedOut {
                        process.terminate()
                        if finished.wait(timeout: .now() + 1) == .timedOut {
                            kill(process.processIdentifier, SIGKILL)
                            process.waitUntilExit()
                        }
                    }
                    func read(_ url: URL) throws -> String {
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        return String(decoding: try handle.read(upToCount: 1_048_576) ?? Data(), as: UTF8.self)
                    }
                    continuation.resume(returning: Result(
                        exitCode: timedOut ? -2 : process.terminationStatus,
                        standardOutput: try read(outURL),
                        standardError: timedOut ? "Shortcut timed out." : try read(errURL)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                } catch {
                    continuation.resume(returning: Result(exitCode: -1, standardOutput: "",
                                                          standardError: "Could not run the command."))
                }
            }
        }
    }
}
