//
//  AgentApplication.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Which app a session belongs to, so a row in the dashboard can take you
//  there.
//
//  This resolves the *maker's* app, not the exact window. Nothing on disk says
//  which terminal a CLI session is running in, and a transcript does not record
//  its own process, so "take me to the session" would mean guessing. Activating
//  Claude or ChatGPT is the honest version of the same gesture: it is what the
//  row's tooltip says it will do, and it does exactly that.
//
//  A row whose app is not installed is not a button. An affordance that does
//  nothing is worse than no affordance.
//

import AppKit

nonisolated enum AgentApplication {
    /// Candidate bundle identifiers per maker, most specific first.
    ///
    /// `com.openai.codex` looks wrong and is not: it is the bundle identifier
    /// of ChatGPT.app on macOS. Read from the installed bundle rather than
    /// assumed, so the surprising one is the checked one.
    static func bundleIDs(for provider: SessionProvider) -> [String] {
        switch provider {
        case .anthropic: ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        case .openAI: ["com.openai.codex", "com.openai.chat"]
        }
    }

    /// The installed app for this maker, if there is one.
    static func url(for provider: SessionProvider) -> URL? {
        for identifier in bundleIDs(for: provider) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                return url
            }
        }
        return nil
    }

    static func isInstalled(_ provider: SessionProvider) -> Bool {
        url(for: provider) != nil
    }

    /// What to call it on screen — the installed bundle's own name where there
    /// is one, so an app the user renamed still reads correctly.
    static func displayName(for provider: SessionProvider) -> String? {
        guard let url = url(for: provider) else { return nil }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    /// Brings the maker's app forward. No-op when it is not installed.
    @discardableResult
    static func open(_ provider: SessionProvider) -> Bool {
        guard let url = url(for: provider) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return true
    }
}
