//
//  PreviewRenderer.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Development aid: renders the notch UI offscreen to PNGs so its appearance
//  can be reviewed and iterated on without a screen recording.
//
//      LocalNook.app/Contents/MacOS/LocalNook --render-preview <output-dir>
//
//  Not reachable in normal operation — the flag is only read at launch.
//

import AppKit
import SwiftUI

enum PreviewRenderer {
    /// Renders each notch state over a mock desktop so contrast and the
    /// blend into the screen edge can be judged the way a user would see it.
    static func run(outputDirectory: URL) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        try? FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true
        )

        // Cover every widget so each one can be reviewed at its real size.
        var scenes: [(name: String, open: Bool, widget: WidgetKind)] = [
            ("closed", false, .media),
            ("closed-activity", false, .media),
            ("dashboard-populated", true, .media),
            ("tray-populated", true, .shelf),
            ("tools", true, .timers),
            ("tray-drag-target", true, .shelf),
        ]
        scenes += WidgetKind.allCases.map { ("open-\($0.rawValue)", true, $0) }

        for scene in scenes {
            let model = NotchViewModel(screenID: NSScreen.main?.stableID)

            // Stage representative content so composed layouts can be judged,
            // rather than reviewing a panel full of empty states.
            if scene.name == "dashboard-populated" {
                MediaManager.shared.previewInject(NowPlaying(
                    sourceID: "music", sourceName: "Music", state: .playing,
                    title: "Fourth of July", artist: "Sufjan Stevens",
                    album: "Carrie & Lowell", duration: 292, position: 96,
                    positionSampledAt: Date(), artworkKey: "preview"
                ))
                model.page = .dashboard
            } else if scene.name == "tray-populated" {
                model.page = .tray
            } else if scene.name == "tray-drag-target" {
                model.page = .tray
                // Stage the drop-target state; a real drag cannot be
                // synthesised without Accessibility.
                model.isDragTargeting = true
            } else if scene.name == "tools" {
                model.page = .tools
            } else {
                MediaManager.shared.previewInject(nil)
            }
            if scene.name == "closed-activity" {
                LiveActivityCenter.shared.previewInject(LiveActivity(
                    id: "preview", symbol: "waveform", tint: .white,
                    leading: "Midnight City", trailing: "M83",
                    style: .persistent, progress: 0.42, priority: 40
                ))
            } else {
                LiveActivityCenter.shared.previewInject(nil)
            }
            model.selectedWidget = scene.widget
            if scene.open { model.open() }

            let size = NotchGeometry.windowSize(for: NSScreen.main)
            let canvas = CGSize(width: size.width, height: size.height + 40)

            let root = ZStack(alignment: .top) {
                MockDesktop()
                NotchRootView(model: model).environmentObject(Settings.shared)
                    .frame(width: size.width, height: size.height)
            }
            .frame(width: canvas.width, height: canvas.height)

            guard let image = render(root, size: canvas) else {
                FileHandle.standardError.write("failed to render \(scene.name)\n".data(using: .utf8)!)
                continue
            }
            let url = outputDirectory.appendingPathComponent("notch-\(scene.name).png")
            if let data = image.representation(using: .png, properties: [:]) {
                try? data.write(to: url)
                print("rendered \(url.lastPathComponent)  \(Int(canvas.width))×\(Int(canvas.height))")
            }
        }

        exit(0)
    }

    /// Hosts the view in an offscreen window and captures its backing store.
    ///
    /// SwiftUI needs a real window and a layout pass before it will draw, so a
    /// plain `NSHostingView` snapshot without this returns an empty bitmap.
    private static func render<V: View>(_ view: V, size: CGSize) -> NSBitmapImageRep? {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        // Far offscreen so nothing flashes on the user's display.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))

        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFront(nil)

        // Let SwiftUI run layout and the implicit animations settle.
        for _ in 0..<12 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }
}

/// A stand-in desktop wallpaper, so the notch is judged against something other
/// than a transparent void.
private struct MockDesktop: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.35, green: 0.42, blue: 0.62),
                Color(red: 0.62, green: 0.45, blue: 0.52),
                Color(red: 0.30, green: 0.34, blue: 0.44),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay(alignment: .top) {
            // Mock menu bar, to check the closed notch lines up with it.
            Rectangle()
                .fill(.black.opacity(0.28))
                .frame(height: 32)
        }
    }
}
