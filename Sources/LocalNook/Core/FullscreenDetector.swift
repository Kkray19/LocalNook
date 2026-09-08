//
//  FullscreenDetector.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Detects when an app is occupying a whole display, so the collapsed notch can
//  get out of the way of full-screen video.
//
//  Uses the public window list. Only geometry and layer are read — no window
//  titles, no contents — so this needs no Screen Recording permission.
//

import AppKit
import Combine
import CoreGraphics

final class FullscreenDetector: ObservableObject {
    static let shared = FullscreenDetector()

    /// Screens (by stable ID) currently covered by a full-screen window.
    @Published private(set) var coveredScreenIDs: Set<String> = []

    private var timer: AnyCancellable?
    private var isRunning = false

    private init() {}

    /// Space changes are the only reliable signal that a window went full
    /// screen, so we sample on that plus a slow safety tick — and only while
    /// the feature is switched on.
    func start() {
        guard !isRunning, Settings.shared.hideInFullscreen else { return }
        isRunning = true

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        timer = Timer.publish(every: 3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }

        refresh()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        isRunning = false
        coveredScreenIDs = []
    }

    func syncWithSettings() {
        Settings.shared.hideInFullscreen ? start() : stop()
    }

    private func refresh() {
        guard Settings.shared.hideInFullscreen else {
            if !coveredScreenIDs.isEmpty { coveredScreenIDs = [] }
            return
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return }

        var covered: Set<String> = []
        for screen in NSScreen.screens {
            guard let id = screen.stableID else { continue }
            let frame = screen.frame

            for window in list {
                // Layer 0 is the normal application layer; anything above is
                // menu bar, dock or another overlay and does not count.
                guard (window[kCGWindowLayer as String] as? Int) == 0 else { continue }
                guard let owner = window[kCGWindowOwnerName as String] as? String,
                      owner != "LocalNook" else { continue }
                guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                      let width = bounds["Width"], let height = bounds["Height"]
                else { continue }

                // A genuinely full-screen window matches the display within a
                // point or two; a merely maximised one leaves the menu bar.
                if abs(width - frame.width) < 2, abs(height - frame.height) < 2 {
                    covered.insert(id)
                    break
                }
            }
        }

        if covered != coveredScreenIDs { coveredScreenIDs = covered }
    }
}
