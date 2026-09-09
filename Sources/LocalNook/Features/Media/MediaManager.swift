//
//  MediaManager.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import AppKit
import Combine
import SwiftUI

/// Aggregates every media provider into a single Now Playing state.
///
/// Polling discipline matters more than anything else here — an always-on 1 Hz
/// AppleScript poll is exactly the kind of thing that keeps a laptop awake. The
/// rules are:
///
/// * If no supported media app is **running**, do not poll at all. App launches
///   and quits arrive as `NSWorkspace` notifications, not by polling.
/// * If something is playing, poll at the configured interval so the scrubber
///   stays honest.
/// * If everything is paused and the notch is closed, back off to 5s.
final class MediaManager: ObservableObject {
    static let shared = MediaManager()

    @Published private(set) var nowPlaying: NowPlaying = .idle
    @Published private(set) var artwork: NSImage?
    /// Set when Automation consent was refused, so the UI can explain itself.
    @Published private(set) var automationDenied = false

    /// Scripted apps first, browsers last.
    ///
    /// Order is the tie-break when nothing is playing, and a real media app is
    /// a better guess than a browser tab that happens to be open. Browser
    /// providers return nothing at all until the user switches them on.
    private let providers: [any MediaProvider] = [
        MusicAppProvider(),
        SpotifyProvider(),
        BrowserMediaProvider(browser: .chrome),
        BrowserMediaProvider(browser: .safari),
    ]
    private var pollTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var notchIsOpen = false
    private var lastArtworkKey = ""
    private var isPolling = false
    private var monitoringEnabled = false

    private init() {
        observeAppLifecycle()
        observeNotch()
    }

    /// Explicit use of the media widget enables Apple Events; launch never prompts.
    ///
    /// Never during a self-test or a preview render: both stage their own
    /// snapshots, and a poll would replace them with whatever this Mac happens
    /// to be playing — as well as sending Apple Events from a process whose
    /// whole job is to write PNGs.
    func activate() {
        guard !AppInfo.isSelfTest, !AppInfo.isPreviewRender else { return }
        monitoringEnabled = true
        reconsiderPolling()
    }

    /// Starts polling only when doing so cannot cause a new permission prompt.
    ///
    /// The dashboard deliberately never called `activate()`, because opening
    /// the notch must not be the reason macOS asks for Automation consent. The
    /// consequence was that the dashboard's media section said "Nothing
    /// playing" permanently — it was never asking anything, for any source.
    ///
    /// Consent that already exists changes that, and it can now be *read*
    /// rather than inferred: `AutomationPermission.status` answers from the TCC
    /// database without sending an event, so a browser whose answer is already
    /// "yes" can be polled with no dialog possible. The two older conditions
    /// remain for the scripted apps, whose consent is still only observable
    /// through the outcome of an attempt.
    ///
    /// Nothing here is inferred from the widget merely being visible.
    func activateIfAlreadyConsented() {
        guard !AppInfo.isSelfTest, !AppInfo.isPreviewRender else { return }
        guard Settings.shared.browserMediaEnabled
            || MediaScriptBridge.lastAutomationState == .granted
        else { return }
        activate()
    }

    // MARK: Connecting a browser

    /// Browsers that are switched on and running but not yet permitted.
    ///
    /// Their providers report nothing at all rather than prompting, so without
    /// this the widget would just look empty for a reason it never explains.
    var browsersAwaitingConnection: [(browser: MediaBrowser, status: AutomationPermission.Status)] {
        providers.compactMap { provider in
            guard let browserProvider = provider as? BrowserMediaProvider,
                  let status = browserProvider.connectionStatus
            else { return nil }
            return (browserProvider.browser, status)
        }
    }

    /// The deliberate request for Automation consent.
    ///
    /// This is the only call in the app that may raise the system dialog, and
    /// it happens because someone pressed a button asking for exactly that. It
    /// is also what creates the app's entry under System Settings ▸ Privacy &
    /// Security ▸ Automation: that list shows apps that have asked, so until
    /// something asks there is nothing there to switch on. Refusing here is
    /// recoverable — the entry exists afterwards either way.
    ///
    /// Blocks while the dialog is up, so it runs off the main actor.
    func connect(_ browser: MediaBrowser) {
        let bundleID = browser.bundleID
        Task.detached(priority: .userInitiated) {
            let status = AutomationPermission.request(forBundleID: bundleID)
            await MainActor.run {
                Permissions.shared.refreshAll()
                self.objectWillChange.send()
                if status.isGranted {
                    self.activate()
                    self.refreshNow()
                }
            }
        }
    }

    deinit { pollTask?.cancel() }

    // MARK: Availability

    /// Providers whose app is installed and currently running.
    var availableProviders: [any MediaProvider] {
        providers.filter(\.isAvailable)
    }

    var hasAnyRunningSource: Bool { !availableProviders.isEmpty }

    /// Installed but not running — used to explain an empty widget.
    var installedProviderNames: [String] {
        providers
            .filter { MediaScriptBridge.isInstalled(bundleID: $0.bundleID) }
            .map(\.displayName)
    }

    // MARK: Polling

    private func observeAppLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconsiderPolling() }
            }
        }
        // Stop entirely while asleep; resume on wake.
        center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopPolling() }
        }
        center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconsiderPolling() }
        }
    }

    private func observeNotch() {
        NotificationCenter.default.addObserver(
            forName: .notchDidOpen, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.notchIsOpen = true
                self?.reconsiderPolling()
                self?.refreshNow()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .notchDidClose, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.notchIsOpen = false
                self?.reconsiderPolling()
            }
        }
    }

    func reconsiderPolling() {
        guard monitoringEnabled else { return }
        guard hasAnyRunningSource else {
            stopPolling()
            if !nowPlaying.isIdle { nowPlaying = .idle; artwork = nil }
            return
        }
        startPollingIfNeeded()
    }

    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                let interval = self.currentInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Back off hard when nothing is playing and nobody is looking.
    private var currentInterval: Double {
        if nowPlaying.state == .playing {
            return max(0.5, Settings.shared.mediaPollInterval)
        }
        return notchIsOpen ? 1.5 : 5.0
    }

    func refreshNow() {
        Task { await poll() }
    }

    /// Which of several sources to show.
    ///
    /// Ranked by how much is actually known, then made sticky. A source that
    /// reports its own state beats one whose state was inferred from a browser
    /// making a noise, which in turn beats a paused source — so Music playing
    /// is never masked by a Chrome tab that might be, and a Chrome tab that
    /// might be is never masked by Spotify sitting paused in the background.
    ///
    /// Stickiness is the second rule and it matters as much: without it two
    /// equally ranked players swap the widget back and forth on alternate
    /// polls, which makes the panel unreadable and its controls untrustworthy.
    /// It only holds while the incumbent stays in the top rank — when it stops,
    /// the choice is made afresh rather than preserved.
    static func choose(from snapshots: [NowPlaying], current: String) -> NowPlaying? {
        guard !snapshots.isEmpty else { return nil }
        guard let best = snapshots.map(rank).min() else { return nil }
        let tier = snapshots.filter { rank($0) == best }
        if let incumbent = tier.first(where: { $0.sourceID == current }) { return incumbent }
        return tier.first
    }

    /// Lower is more worth showing.
    private static func rank(_ snapshot: NowPlaying) -> Int {
        switch snapshot.state {
        case .playing: 0
        case .unknown: 1
        case .paused: 2
        case .stopped: 3
        }
    }

    private func poll() async {
        guard monitoringEnabled, !isPolling, !Task.isCancelled else { return }
        isPolling = true
        defer { isPolling = false }
        var snapshots: [NowPlaying] = []
        for provider in availableProviders {
            guard let snapshot = await provider.fetch(), provider.isAvailable, !snapshot.isIdle else { continue }
            guard !Task.isCancelled else { return }
            snapshots.append(snapshot)
        }
        let best = Self.choose(from: snapshots, current: nowPlaying.sourceID)

        guard !Task.isCancelled else { return }
        let resolved = best ?? .idle
        automationDenied = MediaScriptBridge.lastAutomationState == .denied

        if resolved != nowPlaying { nowPlaying = resolved }

        if resolved.artworkKey != lastArtworkKey {
            lastArtworkKey = resolved.artworkKey
            artwork = nil
            if !resolved.isIdle,
               let provider = availableProviders.first(where: { $0.id == resolved.sourceID }) {
                artwork = await provider.artwork(for: resolved)
            }
        }
    }

    /// Injects a fixed track. Used only by `--render-preview` so populated
    /// layouts can be reviewed without playing audio on the user's machine.
    func previewInject(_ track: NowPlaying?) {
        nowPlaying = track ?? .idle
        artwork = nil
    }

    // MARK: Transport

    private var activeProvider: (any MediaProvider)? {
        availableProviders.first { $0.id == nowPlaying.sourceID }
    }

    func playPause() {
        guard let provider = activeProvider,
              nowPlaying.capabilities.contains(.playPause) else { return }
        // Reflect the new state immediately; the next poll confirms it.
        nowPlaying.position = nowPlaying.interpolatedPosition
        nowPlaying.state = nowPlaying.state == .playing ? .paused : .playing
        nowPlaying.positionSampledAt = Date()
        Task {
            await provider.playPause()
            try? await Task.sleep(for: .milliseconds(250))
            await poll()
        }
    }

    func next() {
        guard let provider = activeProvider else { return }
        Task {
            await provider.next()
            try? await Task.sleep(for: .milliseconds(350))
            await poll()
        }
    }

    func previous() {
        guard let provider = activeProvider else { return }
        Task {
            await provider.previous()
            try? await Task.sleep(for: .milliseconds(350))
            await poll()
        }
    }

    func seek(toFraction fraction: Double) {
        guard let provider = activeProvider,
              nowPlaying.capabilities.contains(.seek),
              nowPlaying.duration > 0 else { return }
        let seconds = max(0, min(nowPlaying.duration, fraction * nowPlaying.duration))
        nowPlaying.position = seconds
        nowPlaying.positionSampledAt = Date()
        Task {
            await provider.seek(to: seconds)
            try? await Task.sleep(for: .milliseconds(200))
            await poll()
        }
    }

    /// Opens the app that owns the current track.
    func revealSource() {
        guard let provider = activeProvider,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: provider.bundleID)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}
