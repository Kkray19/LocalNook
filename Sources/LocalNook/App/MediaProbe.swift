//
//  MediaProbe.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  `LocalNook --media-probe`: what each media provider reports, right now.
//
//  Exists because a provider that returns nothing is ambiguous — the app may
//  have been refused permission, or the source may genuinely be idle — and that
//  distinction is invisible from the outside. Running inside the real bundle is
//  the point: it inherits the same Automation consent the app has.
//
//  Deliberately prints no titles. What someone is watching is not diagnostic
//  information, and a probe that leaks it into a terminal scrollback or a bug
//  report would be a worse problem than the one it solves.
//

import AppKit
import Foundation

enum MediaProbe {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        print("LocalNook media probe")
        print("browser media enabled: \(Settings.shared.browserMediaEnabled)")
        print("")

        let providers: [any MediaProvider] = [
            MusicAppProvider(),
            SpotifyProvider(),
            BrowserMediaProvider(browser: .chrome),
            BrowserMediaProvider(browser: .safari),
        ]

        let group = DispatchGroup()
        for provider in providers {
            let installed = MediaScriptBridge.isInstalled(bundleID: provider.bundleID)
            let running = MediaScriptBridge.isRunning(bundleID: provider.bundleID)
            print("\(provider.displayName)")
            print("  installed=\(installed) running=\(running) available=\(provider.isAvailable)")
            guard provider.isAvailable else { print(""); continue }

            group.enter()
            Task {
                let snapshot = await provider.fetch()
                if let snapshot {
                    print("  state=\(snapshot.state) titleLength=\(snapshot.title.count)"
                          + " source=\(snapshot.artist)")
                    print("  duration=\(Int(snapshot.duration))s position=\(Int(snapshot.position))s"
                          + " unknownDuration=\(snapshot.durationIsUnknown)")
                    print("  capabilities: playPause=\(snapshot.capabilities.contains(.playPause))"
                          + " seek=\(snapshot.capabilities.contains(.seek))"
                          + " position=\(snapshot.capabilities.contains(.position))")
                } else {
                    print("  fetch returned nothing")
                }
                print("  automation state after asking: \(MediaScriptBridge.lastAutomationState)")
                print("")
                group.leave()
            }
        }

        // The providers are async and this is a command-line run, so the run
        // loop has to be pumped rather than blocked on.
        let deadline = Date().addingTimeInterval(20)
        while group.wait(timeout: .now() + 0.05) == .timedOut, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        exit(0)
    }
}
