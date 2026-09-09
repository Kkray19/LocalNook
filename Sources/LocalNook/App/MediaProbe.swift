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
    /// Says whose consent these answers actually describe.
    ///
    /// Learned the hard way: run from a shell, this probe reported Chrome as
    /// "Connected" while the app's own dashboard said "Google Chrome isn't
    /// connected" — and the dashboard was right. Automation consent is granted
    /// to a *client*, and macOS attributes a process launched from a terminal
    /// to the terminal that launched it. So a probe run this way can report the
    /// terminal's permissions wearing LocalNook's name.
    ///
    /// Rather than quietly mislead, it names its parent and says what that
    /// means. The authoritative answer is the one the running app shows.
    private static func printAttributionCaveat() {
        var parentName = "unknown"
        var buffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(getppid(), &buffer, UInt32(buffer.count)) > 0 {
            parentName = (String(cString: buffer) as NSString).lastPathComponent
        }
        print("  launched by: \(parentName) (pid \(getppid()))")
        guard parentName != "launchd" else { return }
        print("  NOTE: consent is per client, and macOS attributes a process")
        print("        launched from a terminal to that terminal. These answers")
        print("        may be \(parentName)'s, not the running app's. What the")
        print("        app itself has is what its dashboard shows.")
    }

    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        print("LocalNook media probe")
        print("browser media enabled: \(Settings.shared.browserMediaEnabled)")
        print("")
        print("Automation consent, read without sending an event:")
        for bundleID in ["com.apple.Music", "com.spotify.client",
                         "com.google.Chrome", "com.apple.Safari"] {
            let running = MediaScriptBridge.isRunning(bundleID: bundleID)
            print("  \(bundleID): \(AutomationPermission.status(forBundleID: bundleID).label)"
                  + " (running=\(running))")
        }
        printAttributionCaveat()
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

            // A browser that is unavailable is the interesting case, not the
            // one to skip: it says which of enabled, running and permitted is
            // missing, which is exactly what a blank widget will not tell you.
            if let browserProvider = provider as? BrowserMediaProvider,
               !provider.isAvailable {
                group.enter()
                Task {
                    print(await browserProvider.diagnostics())
                    print("")
                    group.leave()
                }
                continue
            }
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
                if let browserProvider = provider as? BrowserMediaProvider {
                    print(await browserProvider.diagnostics())
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
