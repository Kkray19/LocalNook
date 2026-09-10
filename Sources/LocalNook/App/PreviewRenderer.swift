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
        // A chosen width implies a throwaway defaults suite, so this neither
        // reads nor writes the width the user actually set.
        if let width = AppInfo.previewWidth { Settings.shared.openWidth = width }

        var scenes: [(name: String, open: Bool, widget: WidgetKind)] = [
            ("closed", false, .media),
            ("closed-activity", false, .media),
            ("closed-agent-claude", false, .media),
            ("closed-agent-openai", false, .media),
            ("closed-agent-mixed", false, .media),
            ("closed-agent-expanded", false, .media),
            ("dashboard-populated", true, .media),
            ("dashboard-browser-audio", true, .media),
            ("dashboard-browser-ambiguous", true, .media),
            ("dashboard-browser-page", true, .media),
            ("sessions-dashboard", true, .sessions),
            ("sessions-tokens", true, .sessions),
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
            } else if scene.name == "dashboard-browser-audio" {
                // Tier 1, one player tab: the browser is audibly playing, and
                // which tab that is cannot be established. Staged, not observed.
                MediaManager.shared.previewInject(NowPlaying(
                    sourceID: "browser.chrome", sourceName: "Google Chrome",
                    state: .unknown, title: "Ludovico Einaudi — Nuvole Bianche",
                    artist: "YouTube", album: "", duration: 0, position: 0,
                    positionSampledAt: Date(), artworkKey: "",
                    capabilities: .titleOnly, durationIsUnknown: true
                ))
                model.page = .dashboard
            } else if scene.name == "dashboard-browser-ambiguous" {
                // Tier 1, several player tabs: no tab may be named at all.
                MediaManager.shared.previewInject(NowPlaying(
                    sourceID: "browser.chrome", sourceName: "Google Chrome",
                    state: .unknown, title: "Browser audio active",
                    artist: "Google Chrome · 3 media tabs", album: "",
                    duration: 0, position: 0, positionSampledAt: Date(),
                    artworkKey: "", capabilities: .titleOnly,
                    durationIsUnknown: true, sourceIsAmbiguous: true
                ))
                model.page = .dashboard
            } else if scene.name == "dashboard-browser-page" {
                // Tier 2: the page named itself, so state, position and
                // controls are all real.
                MediaManager.shared.previewInject(NowPlaying(
                    sourceID: "browser.chrome", sourceName: "Google Chrome",
                    state: .playing, title: "Ludovico Einaudi — Nuvole Bianche",
                    artist: "YouTube", album: "", duration: 366, position: 128,
                    positionSampledAt: Date(), artworkKey: "",
                    capabilities: [.playbackState, .position, .playPause, .seek]
                ))
                model.page = .dashboard
            } else if scene.name.hasPrefix("sessions-") {
                // Invented sessions, for the same reason as the badge scenes
                // below: the renderer must not open a transcript, so nothing
                // here came from one.
                func staged(
                    _ agent: SessionAgent, _ id: String, _ project: String,
                    secondsAgo: TimeInterval, bytes: Int,
                    model modelName: String? = nil, effort: String? = nil,
                    title: String? = nil, step: String? = nil
                ) -> AgentSession {
                    var value = AgentSession(
                        id: id, agent: agent, projectName: project,
                        lastActivity: Date().addingTimeInterval(-secondsAgo), byteSize: bytes
                    )
                    value.detail.model = modelName
                    value.detail.effort = effort
                    value.detail.title = title
                    value.detail.step = step
                    value.detail.activity = step == nil ? .recent : .working
                    value.detail.wasNotRead = false
                    return value
                }
                // Limits and token counts of the shape Codex writes. Invented
                // like everything else here — but the *shape* is real, which
                // is the part a layout has to survive.
                func limits(_ percent: Double, _ weekly: Double) -> [RateLimitWindow] {
                    [
                        RateLimitWindow(provider: .openAI, windowMinutes: 300,
                                        usedPercent: percent,
                                        resetsAt: Date().addingTimeInterval(15_000),
                                        observedAt: Date().addingTimeInterval(-20)),
                        RateLimitWindow(provider: .openAI, windowMinutes: 10080,
                                        usedPercent: weekly,
                                        resetsAt: Date().addingTimeInterval(440_000),
                                        observedAt: Date().addingTimeInterval(-20)),
                    ]
                }
                var codexRunning = staged(
                    .codex, "2", "2026-09-09T14", secondsAgo: 22, bytes: 812_000,
                    model: "GPT 6 Astra", effort: "high", title: "LedgerApp",
                    step: "Reading a file"
                )
                codexRunning.detail.tokens = TokenUsage(
                    input: 18_487_073, cachedInput: 17_964_416, output: 76_339,
                    reasoning: 18_081, total: 18_563_412
                )
                codexRunning.detail.limits = limits(40, 52)
                var codexOlder = staged(.codex, "5", "2026-09-08T09",
                                        secondsAgo: 90_000, bytes: 210_000,
                                        model: "GPT 6 Astra")
                codexOlder.detail.tokens = TokenUsage(
                    input: 402_000, cachedInput: 380_000, output: 9_400,
                    reasoning: 1_200, total: 411_400
                )
                let staging = [
                    staged(.claudeCode, "1", "LedgerApp", secondsAgo: 4, bytes: 3_400_000,
                           model: "Opus 5", effort: "xhigh", title: "Statement importer",
                           step: "Running the test suite"),
                    codexRunning,
                    staged(.claudeCode, "3", "Notch", secondsAgo: 640, bytes: 41_000_000,
                           model: "Opus 5", effort: "high", title: "Opening animation"),
                    staged(.claudeCode, "4", "Notch", secondsAgo: 5400, bytes: 96_000,
                           model: "Sonnet 5"),
                    codexOlder,
                ]
                SessionsDashboardView.previewMode =
                    scene.name == "sessions-tokens" ? .models : .sessions
                SessionMonitor.shared.previewInject(
                    staging, stats: SessionStats.tally(staging)
                )
                model.page = .tools
                model.focusedTool = .sessions
                model.focusedToolOrigin = .dashboard
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
            // No Liquid Glass scenes here. `.glassEffect` samples what is
            // actually behind the window, and an offscreen render has nothing
            // behind it: rendered at 100% and at 45% opacity the two came out
            // near-identical, both with rainbow fringing along the flares. A
            // preview that misrepresents the thing being previewed is worse
            // than no preview, so glass is judged on screen instead.

            // The agent badge and the trailing indicator, staged rather than
            // read: the renderer is forbidden from opening a transcript, and
            // these names are invented for exactly that reason.
            if scene.name.hasPrefix("closed-agent") {
                let provider: SessionProvider? = switch scene.name {
                case "closed-agent-openai": .openAI
                case "closed-agent-mixed": nil
                default: .anthropic
                }
                LiveActivityCenter.shared.previewInject(LiveActivity(
                    id: "preview.agents",
                    symbol: provider?.symbol ?? SessionProvider.mixedSymbol,
                    tint: provider.map(LiveActivityCenter.tint(for:)) ?? .green,
                    leading: provider == nil ? "3 agents" : "Opus 5 xhigh",
                    trailing: "", style: .persistent, progress: nil, priority: 30,
                    isBusy: true,
                    details: [
                        LiveActivityDetail(id: "1", symbol: SessionAgent.claudeCode.symbol,
                                           name: "LedgerApp", step: "Running the test suite"),
                        LiveActivityDetail(id: "2", symbol: SessionAgent.codex.symbol,
                                           name: "Site", step: "Reading a file"),
                    ]
                ))
                LiveActivityCenter.shared.setTrailingExpanded(
                    scene.name == "closed-agent-expanded"
                )
            } else if scene.name == "closed-activity" {
                LiveActivityCenter.shared.previewInject(LiveActivity(
                    id: "preview", symbol: "waveform", tint: .white,
                    leading: "Midnight City", trailing: "M83",
                    style: .persistent, progress: 0.42, priority: 40
                ))
            } else {
                LiveActivityCenter.shared.setTrailingExpanded(false)
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
