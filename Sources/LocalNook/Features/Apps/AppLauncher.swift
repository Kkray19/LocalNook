//
//  AppLauncher.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Quick Apps: a handful of apps pinned around the notch, each a click from
//  opening. NotchNook's launcher, rebuilt from LocalNook's own app-opening
//  code — the same NSWorkspace path the AI Sessions rows already use.
//
//  What is stored is a bundle identifier, not a path: an app moved or updated
//  keeps working, and nothing here records where on disk anything lives. A
//  pinned app whose bundle is no longer installed is dropped from the list
//  rather than shown as a dead tile.
//

import AppKit
import Combine

/// One pinned app, resolved from its bundle identifier to something openable.
nonisolated struct PinnedApp: Identifiable, Equatable, Sendable {
    let bundleID: String
    let url: URL
    let name: String

    var id: String { bundleID }
}

final class AppLauncher: ObservableObject {
    static let shared = AppLauncher()

    /// Bumped when the pin list changes, so views resolve icons afresh.
    @Published private(set) var revision = 0

    private init() {}

    /// The pinned apps that are actually installed, in the user's order.
    var pinned: [PinnedApp] {
        Self.resolve(Settings.shared.pinnedAppBundleIDs)
    }

    var canPinMore: Bool { Settings.shared.pinnedAppBundleIDs.count < Self.maximum }
    static let maximum = 12

    /// Resolves bundle identifiers to installed apps, dropping any that are not
    /// installed and de-duplicating while preserving order.
    static func resolve(_ bundleIDs: [String]) -> [PinnedApp] {
        var seen = Set<String>()
        return bundleIDs.compactMap { id in
            guard seen.insert(id).inserted,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            else { return nil }
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            return PinnedApp(bundleID: id, url: url, name: name)
        }
    }

    /// The stored list with `bundleID` added at the end, de-duplicated and
    /// capped. Pure, so pin/unpin ordering is tested without touching defaults.
    static func adding(_ bundleID: String, to existing: [String]) -> [String] {
        guard !bundleID.isEmpty, !existing.contains(bundleID) else { return existing }
        return Array((existing + [bundleID]).prefix(maximum))
    }

    static func removing(_ bundleID: String, from existing: [String]) -> [String] {
        existing.filter { $0 != bundleID }
    }

    func pin(_ url: URL) {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        Settings.shared.pinnedAppBundleIDs = Self.adding(id, to: Settings.shared.pinnedAppBundleIDs)
        revision += 1
    }

    func unpin(_ bundleID: String) {
        Settings.shared.pinnedAppBundleIDs =
            Self.removing(bundleID, from: Settings.shared.pinnedAppBundleIDs)
        revision += 1
    }

    func launch(_ app: PinnedApp) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: configuration)
    }

    func icon(for app: PinnedApp) -> NSImage {
        NSWorkspace.shared.icon(forFile: app.url.path)
    }

    /// Opens a picker rooted at /Applications so an app can be pinned. Main
    /// actor: it stands up a panel. No-op if the user cancels.
    @MainActor
    func promptToPin() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Pin"
        panel.message = "Choose an app to pin to the notch."
        if panel.runModal() == .OK, let url = panel.url { pin(url) }
    }
}
