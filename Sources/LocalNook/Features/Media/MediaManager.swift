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

    private let providers: [any MediaProvider] = [MusicAppProvider(), SpotifyProvider()]
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
    func activate() {
        guard !AppInfo.isSelfTest else { return }
        monitoringEnabled = true
        reconsiderPolling()
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

    /// Picks the most interesting snapshot: a playing source always wins over a
    /// paused one, so having Music paused in the background does not mask
    /// Spotify actually playing.
    private func poll() async {
        guard monitoringEnabled, !isPolling, !Task.isCancelled else { return }
        isPolling = true
        defer { isPolling = false }
        var best: NowPlaying?
        for provider in availableProviders {
            guard let snapshot = await provider.fetch(), provider.isAvailable, !snapshot.isIdle else { continue }
            guard !Task.isCancelled else { return }
            if best == nil || (snapshot.state == .playing && best?.state != .playing) {
                best = snapshot
            }
        }

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

    // MARK: Transport

    private var activeProvider: (any MediaProvider)? {
        availableProviders.first { $0.id == nowPlaying.sourceID }
    }

    func playPause() {
        guard let provider = activeProvider else { return }
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
        guard let provider = activeProvider, nowPlaying.duration > 0 else { return }
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
