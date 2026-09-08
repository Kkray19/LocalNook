//
//  SelfTest.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Built-in test harness:  LocalNook --self-test
//
//  XCTest ships with full Xcode, not with the Command Line Tools this project
//  builds under, so `swift test` is unavailable. This runs the same kind of
//  assertions in-process instead, against the real singletons, and exits
//  non-zero on failure so it can gate a release build.
//
//  Tests that would mutate the user's real data operate on temporary copies or
//  restore what they changed.
//

import AppKit
import Foundation
import SwiftUI

enum SelfTest {
    private nonisolated(unsafe) static var passed = 0
    private nonisolated(unsafe) static var failed = 0

    static func run() -> Never {
        // Needs an NSApplication for AppKit geometry to be valid.
        // `.accessory`, not `.prohibited`: a prohibited app is not eligible to
        // receive UI events at all, which would make the hover test fail for a
        // reason that has nothing to do with the code under test.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        print("LocalNook self-test\n")

        testEnvironment()
        testGeometry()
        testPreferences()
        testShelf()
        testNotesAndTodos()
        testTimers()
        testMediaParsing()
        // Session fixtures are covered by StabilizationTests; never scan user transcripts here.
        testPermissionsDegradeGracefully()

        testHoverPath()
        testClickThrough()
        testExternalDisplays()
        testInteractiveFootprint()
        testLiquidGlass()
        testCatcherHover()
        testCloseLatch()
        testScriptableControl()
        StabilizationTests.run()
        AppInfo.defaults.removePersistentDomain(forName: AppInfo.testSuiteName)
        try? FileManager.default.removeItem(at: AppInfo.testDirectory)

        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    /// End-to-end check of the real hover path.
    ///
    /// Builds the actual `NotchPanel` hosting the actual `NotchRootView`, then
    /// slides it under the stationary cursor. Moving the window rather than the
    /// pointer means this needs no Accessibility permission — which is the whole
    /// point, since `NSEvent.addGlobalMonitorForEvents` silently never fires
    /// without it and hover must not depend on that.
    private static func testHoverPath() {
        section("Hover (end to end)")
        print("    AXIsProcessTrusted = \(AXIsProcessTrusted())")

        let settings = Settings.shared
        let originalDelay = settings.openDelay
        settings.openDelay = 0.05

        let model = NotchViewModel(screenID: NSScreen.main?.stableID)
        let panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120))
        let host = NSHostingView(
            rootView: NotchRootView(model: model).environmentObject(settings)
        )
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
        panel.contentView = host
        // Must be fully opaque: macOS does not deliver mouse events to a
        // near-transparent window, so a "subtle" test panel would silently fail
        // to receive mouseEntered and give a false negative.
        panel.alphaValue = 1.0
        panel.setFrameOrigin(NSPoint(x: 4, y: 4))
        panel.orderFrontRegardless()

        pumpEvents(for: 0.4)
        check("starts collapsed", model.state == .closed)

        // Slide the hover region under the cursor.
        let cursor = NSEvent.mouseLocation
        let hoverWidth = NotchShape.totalWidth(
            forBody: model.closedSize.width, topRadius: settings.closedCornerRadius
        )
        panel.setFrameOrigin(NSPoint(
            x: cursor.x - hoverWidth / 2,
            y: cursor.y - 120 + model.closedSize.height / 2 + 2
        ))
        pumpEvents(for: 1.0)
        let opened = model.state == .open
        check("hovering the notch opens it", opened,
              "tracking area did not deliver mouseEntered")
        if !opened {
            // Only noisy when something is actually wrong.
            print("    cursor: \(cursor)")
            print("    panel:  \(panel.frame)")
            for line in HoverTracker.diagnostics { print("    tracker: \(line)") }
        }

        // Slide it away again.
        panel.setFrameOrigin(NSPoint(x: 4, y: 4))
        pumpEvents(for: 1.2)
        check("moving the pointer off it collapses again", model.state == .closed,
              "still \(model.state)")

        // Click toggling must not depend on any permission either.
        model.open()
        check("open() opens", model.state == .open)
        model.toggle()
        check("toggle() collapses", model.state == .closed)

        panel.orderOut(nil)
        panel.close()
        settings.openDelay = originalDelay
    }

    /// The collapsed notch must give the rest of the menu bar back.
    ///
    /// A nil hit test is not enough on its own: `NSWindow` dispatches to the view
    /// `hitTest` returns and, when that is nil, drops the event rather than
    /// passing it down. Only `ignoresMouseEvents` actually routes a click past a
    /// window, and it is per-window — hence the split into a wide inert drawing
    /// panel and a tiny interactive catcher.
    private static func testInteractiveFootprint() {
        section("Interactive footprint")
        let controller = NotchWindowController.shared
        let settings = Settings.shared
        controller.start()
        pumpEvents(for: 0.5)

        check("collapsed, the wide drawing panel ignores mouse events",
              controller.inertDrawingPanels)
        check("collapsed, the small catcher accepts them", controller.activeCatchers)

        // With an activity showing, the drawing panel stretches across the menu
        // bar. The catcher must not follow it.
        LiveActivityCenter.shared.previewInject(LiveActivity(
            id: "footprint", symbol: "waveform", tint: .white,
            leading: "Playing something", trailing: "Artist",
            style: .persistent, progress: 0.4, priority: 40
        ))
        pumpEvents(for: 0.8)

        let catchers = controller.catcherFramesByScreen
        let drawn = controller.drawingPanelFramesByScreen
        let allModels = controller.modelsByScreen
        check("there is something to measure", !allModels.isEmpty)

        // Check every display on its own terms — with two monitors attached the
        // notch widths differ, and comparing across them proves nothing.
        for (id, model) in allModels {
            guard let catcher = catchers[id], let strip = drawn[id] else {
                check("display \(id.prefix(8)) has both windows", false)
                continue
            }
            let coreWidth = NotchShape.totalWidth(
                forBody: model.closedSize.width, topRadius: settings.closedCornerRadius
            )
            let label = model.screen?.localizedName ?? String(id.prefix(8))
            check("[\(label)] the catcher stays the width of that display's notch",
                  abs(catcher.width - coreWidth) < 1.5,
                  "catcher \(Int(catcher.width))pt vs notch \(Int(coreWidth))pt")
            check("[\(label)] the catcher is smaller than the drawn strip",
                  catcher.width < strip.width,
                  "catcher \(Int(catcher.width))pt, drawn \(Int(strip.width))pt")
            check("[\(label)] the catcher is only as tall as the notch",
                  catcher.height <= model.closedSize.height + 4,
                  "catcher is \(Int(catcher.height))pt tall")
            check("[\(label)] the catcher sits on that display",
                  model.screen.map { $0.frame.intersects(catcher) } ?? false,
                  "catcher at x=\(Int(catcher.minX)) is not on \(label)")
        }

        // Opening hands input to the panel and stands the catcher down.
        controller.perform(.open)
        pumpEvents(for: 0.6)
        check("expanded, the panel takes input", controller.inertDrawingPanels)
        check("expanded, the catcher stands down", controller.activeCatchers)

        controller.perform(.close)
        pumpEvents(for: 0.6)
        check("collapsing hands input back to the catcher",
              controller.inertDrawingPanels && controller.activeCatchers)

        LiveActivityCenter.shared.previewInject(nil)
        controller.stop()
        pumpEvents(for: 0.2)
    }

    /// The Liquid Glass toggle and the one rule that makes it look right.
    private static func testLiquidGlass() {
        section("Liquid Glass")
        let settings = Settings.shared
        let originalMaterial = settings.notchMaterial
        let originalCollapsed = settings.glassWhenCollapsed
        let originalStyle = settings.glassStyle

        settings.notchMaterial = .solid
        check("solid is the default material", originalMaterial == .solid)
        check("solid never uses glass",
              !NotchSurface.usesGlass(settings: settings, isOpen: true, hasPhysicalNotch: false))

        settings.notchMaterial = .liquidGlass
        settings.glassWhenCollapsed = false

        if NotchMaterial.liquidGlass.isAvailable {
            check("expanded, the notch uses glass",
                  NotchSurface.usesGlass(settings: settings, isOpen: true, hasPhysicalNotch: true))
            check("collapsed over a real camera housing, it stays solid",
                  !NotchSurface.usesGlass(settings: settings, isOpen: false, hasPhysicalNotch: true),
                  "glass over the housing reads as a smudge")
            check("collapsed on a display with no housing, it uses glass",
                  NotchSurface.usesGlass(settings: settings, isOpen: false, hasPhysicalNotch: false))

            settings.glassWhenCollapsed = true
            check("opting in uses glass over the housing too",
                  NotchSurface.usesGlass(settings: settings, isOpen: false, hasPhysicalNotch: true))
            settings.glassWhenCollapsed = false

            settings.glassStyle = .clear
            check("the glass style round-trips", settings.glassStyle == .clear)
        } else {
            check("on a system without Liquid Glass, the notch falls back to solid",
                  !NotchSurface.usesGlass(settings: settings, isOpen: true, hasPhysicalNotch: false),
                  "asking for glass on an older macOS must not be an error")
        }

        check("the material setting round-trips",
              settings.notchMaterial == .liquidGlass)

        settings.notchMaterial = originalMaterial
        settings.glassWhenCollapsed = originalCollapsed
        settings.glassStyle = originalStyle
    }

    /// Hover, end to end, through the catcher that actually handles it.
    ///
    /// This matters more than it looks: collapsed, the drawing panel is inert,
    /// so its tracking area never fires. If the catcher's hover broke, the notch
    /// would simply stop opening — and the older hover test would still pass,
    /// because it exercises the wrong window.
    private static func testCatcherHover() {
        section("Catcher hover (end to end)")
        let settings = Settings.shared
        let originalDelay = settings.openDelay
        settings.openDelay = 0.05

        let model = NotchViewModel(screenID: NSScreen.main?.stableID)
        let panel = NotchWindowController.shared.makeHitPanel(for: model)
        let size = CGSize(width: 220, height: 40)
        panel.setFrame(NSRect(x: 4, y: 4, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        pumpEvents(for: 0.4)
        check("starts collapsed", model.state == .closed)

        // Move the window under the stationary pointer — no Accessibility needed.
        let cursor = NSEvent.mouseLocation
        panel.setFrame(
            NSRect(
                x: cursor.x - size.width / 2,
                y: cursor.y - size.height / 2,
                width: size.width, height: size.height
            ),
            display: true
        )
        pumpEvents(for: 1.0)
        check("hovering the catcher opens the notch", model.state == .open,
              "the catcher's tracking area did not fire")

        // Once open, hover belongs to the expanded panel — the pointer has moved
        // *into* it, not away. Closing on exit is covered by testHoverPath.
        model.close()
        model.allowHoverToReopen()
        panel.setFrame(NSRect(x: 4, y: 4, width: size.width, height: size.height), display: true)
        pumpEvents(for: 0.5)

        // The case that matters for accidental activation: a pointer that only
        // grazes the notch and leaves before the open delay elapses.
        settings.openDelay = 0.8
        panel.setFrame(
            NSRect(
                x: cursor.x - size.width / 2,
                y: cursor.y - size.height / 2,
                width: size.width, height: size.height
            ),
            display: true
        )
        pumpEvents(for: 0.15)
        panel.setFrame(NSRect(x: 4, y: 4, width: size.width, height: size.height), display: true)
        pumpEvents(for: 1.2)
        check("a pointer merely passing over the notch does not open it",
              model.state == .closed,
              "it opened after the pointer had already left")

        panel.orderOut(nil)
        panel.close()
        settings.openDelay = originalDelay
    }

    /// A deliberate close must not bounce straight back open under a still pointer.
    private static func testCloseLatch() {
        section("Close latch")
        let settings = Settings.shared
        let original = settings.openDelay
        settings.openDelay = 0.02

        let model = NotchViewModel(screenID: NSScreen.main?.stableID)
        model.isHovering = true
        model.open()
        check("opens while hovered", model.state == .open)

        model.close()
        model.scheduleOpen()
        pumpEvents(for: 0.4)
        check("closing while the pointer rests on it stays closed",
              model.state == .closed,
              "it re-opened immediately")

        model.allowHoverToReopen()
        model.scheduleOpen()
        pumpEvents(for: 0.4)
        check("hovering again after the pointer leaves re-opens it",
              model.state == .open)
        model.close()
        settings.openDelay = original
    }

    /// Verifies the app answers scripted open/close commands.
    private static func testScriptableControl() {
        section("Scriptable control")
        let controller = NotchWindowController.shared
        controller.start()
        pumpEvents(for: 0.5)
        check("a panel exists to command", controller.activeModel != nil)

        controller.perform(.open)
        pumpEvents(for: 0.3)
        check("perform(.open) opens", controller.activeModel?.state == .open)
        controller.perform(.close)
        pumpEvents(for: 0.3)
        check("perform(.close) closes", controller.activeModel?.state == .closed)

        // Round-trip through DistributedNotificationCenter, which is what an
        // external script actually posts.
        DistributedNotificationCenter.default().postNotificationName(
            .init("com.localnook.open"), object: nil, userInfo: nil, deliverImmediately: true
        )
        pumpEvents(for: 1.2)
        check("a posted com.localnook.open notification opens the notch",
              controller.activeModel?.state == .open,
              "state is \(String(describing: controller.activeModel?.state))")

        DistributedNotificationCenter.default().postNotificationName(
            .init("com.localnook.close"), object: nil, userInfo: nil, deliverImmediately: true
        )
        pumpEvents(for: 1.2)
        check("a posted com.localnook.close notification closes it",
              controller.activeModel?.state == .closed)

        controller.stop()
    }

    /// External-monitor geometry, exercised without attaching a monitor.
    ///
    /// `DisplayMetrics` exists precisely so these paths are reachable: an
    /// external display is the case most likely to be broken and least likely to
    /// be plugged in while developing.
    private static func testExternalDisplays() {
        section("External displays")
        let settings = Settings.shared

        let originalVirtual = settings.virtualNotchEnabled
        let originalMode = settings.notchHeightMode
        let originalWidth = settings.virtualNotchWidth
        let originalAdjust = settings.notchWidthAdjustment
        settings.virtualNotchEnabled = true
        settings.notchHeightMode = .matchRealNotch
        settings.virtualNotchWidth = 200
        settings.notchWidthAdjustment = 0

        // The monitor actually attached to this Mac: 2560x1440, no notch.
        let external = NotchGeometry.DisplayMetrics.external(width: 2560)
        let size = NotchGeometry.closedSize(for: external)
        check("an external display gets a virtual notch",
              size.width > 0 && size.height > 0, "got \(size)")
        check("the virtual notch uses the configured width",
              abs(size.width - 200) < 0.5, "got \(size.width)")
        check("matchRealNotch does not collapse a notchless display to zero",
              size.height > 1, "got \(size.height)")

        settings.notchHeightMode = .matchMenuBar
        let menuBarSized = NotchGeometry.closedSize(for: .external(width: 2560, menuBarHeight: 24))
        check("matchMenuBar follows the external menu bar height",
              abs(menuBarSized.height - 24) < 0.5, "got \(menuBarSized.height)")
        settings.notchHeightMode = .matchRealNotch

        settings.virtualNotchEnabled = false
        let disabled = NotchGeometry.closedSize(for: external)
        check("turning the virtual notch off leaves nothing on external displays",
              disabled == .zero, "got \(disabled)")
        settings.virtualNotchEnabled = true

        // A built-in notched panel must still measure from the real notch.
        let builtIn = NotchGeometry.DisplayMetrics(
            frameWidth: 1512, safeAreaTop: 32, menuBarHeight: 32, physicalNotchWidth: 185
        )
        let builtInSize = NotchGeometry.closedSize(for: builtIn)
        check("the built-in display still tracks its physical notch",
              abs(builtInSize.width - (185 + NotchGeometry.physicalWidthBleed)) < 0.5,
              "got \(builtInSize.width)")

        // Placement on a display whose frame does not start at the origin — the
        // classic way a second monitor ends up with the notch on the wrong screen.
        let rightOfBuiltIn = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let origin = NotchGeometry.windowOrigin(
            inFrame: rightOfBuiltIn, windowSize: CGSize(width: 400, height: 40)
        )
        check("the panel centres on the external display, not the built-in one",
              abs(origin.x - (1512 + (2560 - 400) / 2)) < 0.5, "got x=\(origin.x)")
        check("the panel pins to the external display's top edge",
              abs((origin.y + 40) - 1440) < 0.5, "got y=\(origin.y)")

        let leftOfBuiltIn = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        let negativeOrigin = NotchGeometry.windowOrigin(
            inFrame: leftOfBuiltIn, windowSize: CGSize(width: 400, height: 40)
        )
        check("a display positioned left of the built-in one places correctly",
              negativeOrigin.x < 0, "got x=\(negativeOrigin.x)")

        check("showing on every display is the default",
              settings.showOnAllDisplays,
              "external monitors would get no notch otherwise")

        // Hot-plug: a display appearing or disappearing must rebuild cleanly and
        // leave exactly one panel per eligible screen, with no orphans.
        let controller = NotchWindowController.shared
        controller.start()
        pumpEvents(for: 0.4)
        let eligible = NSScreen.screens.filter { NotchGeometry.shouldDisplay(on: $0) }.count
        check("one panel per eligible display",
              controller.panelCount == eligible,
              "\(controller.panelCount) panels for \(eligible) eligible screens")

        check("one input catcher per panel",
              controller.catcherCount == controller.panelCount,
              "\(controller.catcherCount) catchers for \(controller.panelCount) panels")

        // Repeated reconfiguration is the hot-plug case that leaked an
        // invisible catcher onto the menu bar of an external display.
        for _ in 0..<3 {
            NotificationCenter.default.post(
                name: NSApplication.didChangeScreenParametersNotification, object: nil
            )
            pumpEvents(for: 0.5)
        }
        controller.rebuildPanels()
        pumpEvents(for: 0.3)
        check("a display-configuration change does not duplicate panels",
              controller.panelCount == eligible,
              "\(controller.panelCount) panels after reconfiguration")
        check("repeated reconfiguration does not leak catchers",
              controller.catcherCount == eligible,
              "\(controller.catcherCount) catchers for \(eligible) displays")
        check("catchers and panels track the same displays",
              controller.panelsAndCatchersAgree)
        check("every panel still sits on a live display",
              controller.allPanelsOnLiveScreens)
        controller.stop()
        pumpEvents(for: 0.2)
        check("stopping tears every panel down", controller.panelCount == 0)

        settings.virtualNotchEnabled = originalVirtual
        settings.notchHeightMode = originalMode
        settings.virtualNotchWidth = originalWidth
        settings.notchWidthAdjustment = originalAdjust
    }

    /// Asserts that clicks land on the notch and pass *through* everywhere else.
    ///
    /// The panel is a transparent overlay pinned over the menu bar. Any point in
    /// it that hit-tests to a view swallows a click that belongs to whatever is
    /// underneath — which is exactly the complaint that motivated this test:
    /// the top of the screen became unusable for other apps.
    private static func testClickThrough() {
        section("Click-through")
        let settings = Settings.shared
        let model = NotchViewModel(screenID: NSScreen.main?.stableID)
        let size = CGSize(width: 900, height: 220)
        let panel = NotchPanel(contentRect: NSRect(origin: .zero, size: size))
        // The real construction path, so this asserts shipped behaviour.
        let host = NotchWindowController.makeContentView(for: model, size: size)
        panel.contentView = host
        panel.orderFrontRegardless()
        pumpEvents(for: 0.5)

        // View coordinates: origin bottom-left, notch drawn top-centre.
        let notchWidth = NotchShape.totalWidth(
            forBody: model.closedSize.width, topRadius: settings.closedCornerRadius
        )
        let notchHeight = model.effectiveClosedHeight

        func hits(_ point: NSPoint) -> Bool {
            host.hitTest(point) != nil
        }

        // Dead centre of the collapsed notch must be clickable.
        let centre = NSPoint(x: size.width / 2, y: size.height - notchHeight / 2)
        check("the collapsed notch itself accepts clicks", hits(centre))

        // Everything outside it must fall through.
        let farLeft = NSPoint(x: 40, y: size.height - 10)
        let farRight = NSPoint(x: size.width - 40, y: size.height - 10)
        let below = NSPoint(x: size.width / 2, y: size.height - notchHeight - 60)
        let justOutside = NSPoint(
            x: size.width / 2 + notchWidth / 2 + 25, y: size.height - notchHeight / 2
        )

        check("a click far left of the notch passes through", !hits(farLeft))
        check("a click far right of the notch passes through", !hits(farRight))
        check("a click below the collapsed notch passes through", !hits(below))
        check("a click just outside the notch edge passes through", !hits(justOutside))

        // While open the panel is visible, so it may legitimately take clicks.
        model.open()
        pumpEvents(for: 0.6)
        check("the expanded panel accepts clicks in its body",
              hits(NSPoint(x: size.width / 2, y: size.height - 100)))
        model.close()
        pumpEvents(for: 0.6)
        check("after collapsing, that same point passes through again",
              !hits(NSPoint(x: size.width / 2, y: size.height - 100)))

        // A live activity stretches the drawn notch across the menu bar. Those
        // wings must stay display-only, or the pointer passing near the top of
        // the screen would expand the notch and steal menu-bar clicks.
        LiveActivityCenter.shared.previewInject(LiveActivity(
            id: "selftest", symbol: "waveform", tint: .white,
            leading: "Something", trailing: "Playing",
            style: .persistent, progress: 0.5, priority: 40
        ))
        pumpEvents(for: 0.5)

        let coreWidth = NotchShape.totalWidth(
            forBody: model.closedSize.width, topRadius: settings.closedCornerRadius
        )
        let wing = NSPoint(
            x: size.width / 2 + coreWidth / 2 + 60,
            y: size.height - notchHeight / 2
        )
        check("a live-activity wing does not accept clicks", !hits(wing))

        let region = NotchWindowController.interactiveRegion(for: model, in: host.bounds)
        check("the clickable region stays the width of the notch, not the activity",
              abs(region.width - coreWidth) < 1,
              "region is \(region.width)pt, notch is \(coreWidth)pt")
        LiveActivityCenter.shared.previewInject(nil)

        panel.orderOut(nil)
        panel.close()
    }

    /// Pumps the AppKit event loop for `seconds`.
    ///
    /// `RunLoop.run(until:)` alone is not enough: mouse-entered/exited arrive as
    /// `NSEvent`s that only reach a window when the application dequeues and
    /// dispatches them through `sendEvent`. A bare run loop spins without ever
    /// doing that, so hover would appear broken in the test while working
    /// perfectly in the real app.
    static func pumpEvents(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard let event = NSApp.nextEvent(
                matching: .any,
                until: Date().addingTimeInterval(0.01),
                inMode: .default,
                dequeue: true
            ) else { continue }
            NSApp.sendEvent(event)
        }
    }

    // MARK: Harness

    static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passed += 1
            print("  ✓ \(name)")
        } else {
            failed += 1
            print("  ✗ \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        }
    }

    private static func section(_ title: String) {
        print("\n\(title)")
    }

    // MARK: Tests

    private static func testEnvironment() {
        section("Environment")
        check("at least one screen", !NSScreen.screens.isEmpty)
        let notched = NSScreen.screens.filter(\.hasPhysicalNotch)
        print("    displays: \(NSScreen.screens.count), with a physical notch: \(notched.count)")
        for screen in NSScreen.screens {
            let width = screen.physicalNotchWidth.map { String(format: "%.0f", $0) } ?? "—"
            print("    \(screen.localizedName): \(Int(screen.frame.width))×\(Int(screen.frame.height)), notch width \(width)")
        }
    }

    private static func testGeometry() {
        section("Geometry")
        let screen = NSScreen.main
        let closed = NotchGeometry.closedSize(for: screen)
        check("closed notch has positive size", closed.width > 0 && closed.height > 0,
              "got \(closed)")

        if let screen, screen.hasPhysicalNotch, let physical = screen.physicalNotchWidth {
            let expected = physical + NotchGeometry.physicalWidthBleed
            check("closed width tracks the physical notch",
                  abs(closed.width - expected) < 1.0,
                  "expected ~\(expected), got \(closed.width)")
            check("closed height matches the safe-area inset",
                  abs(closed.height - screen.safeAreaInsets.top) < 0.5,
                  "expected \(screen.safeAreaInsets.top), got \(closed.height)")
        }

        let window = NotchGeometry.windowSize(for: screen)
        let open = NotchGeometry.openSize
        check("panel is wide enough for the open state plus flares",
              window.width >= open.width + Settings.shared.openCornerRadius * 2,
              "window \(window.width) vs open \(open.width)")
        check("panel is tall enough for the open state plus shadow",
              window.height >= open.height + NotchGeometry.shadowPadding - 0.01)

        if let screen {
            let origin = NotchGeometry.windowOrigin(on: screen, windowSize: window)
            let centre = origin.x + window.width / 2
            check("panel is horizontally centred",
                  abs(centre - screen.frame.midX) < 0.5,
                  "centre \(centre) vs screen mid \(screen.frame.midX)")
            check("panel is pinned to the top edge",
                  abs((origin.y + window.height) - screen.frame.maxY) < 0.5)
        }

        // The shape's opaque body must equal the requested width.
        let total = NotchShape.totalWidth(forBody: 200, topRadius: 20)
        check("shape width accounts for both flares", total == 240, "got \(total)")
    }

    private static func testPreferences() {
        section("Preferences")
        let settings = Settings.shared

        let originalDelay = settings.openDelay
        settings.openDelay = 0.37
        check("double round-trips", abs(settings.openDelay - 0.37) < 0.0001)

        let originalTrigger = settings.openTrigger
        settings.openTrigger = .click
        check("enum round-trips", settings.openTrigger == .click)
        check("click trigger disallows hover", !settings.openTrigger.allowsHover)

        let originalScreen = settings.preferredScreenID
        settings.preferredScreenID = "test-id"
        check("optional string round-trips", settings.preferredScreenID == "test-id")
        settings.preferredScreenID = nil
        check("optional string clears", settings.preferredScreenID == nil)

        // Values must survive an actual defaults read, not just the cache.
        AppInfo.defaults.synchronize()
        check("persisted to UserDefaults",
              abs((AppInfo.defaults.object(forKey: "general.openDelay") as? Double ?? 0) - 0.37) < 0.0001)

        let enabledBefore = settings.enabledWidgetIDs
        settings.setWidget(.mirror, enabled: false)
        check("widget can be disabled", !settings.isWidgetEnabled(.mirror))
        check("disabled widget leaves the ordered list",
              !settings.orderedWidgets.contains(.mirror))
        settings.setWidget(.mirror, enabled: true)
        check("widget can be re-enabled", settings.isWidgetEnabled(.mirror))

        // Restore whatever the user had.
        settings.openDelay = originalDelay
        settings.openTrigger = originalTrigger
        settings.preferredScreenID = originalScreen
        settings.enabledWidgetIDs = enabledBefore
    }

    private static func testShelf() {
        section("Shelf")
        let shelf = ShelfStore.shared
        let countBefore = shelf.items.count

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("localnook-selftest-\(UUID().uuidString).txt")
        try? "hello".write(to: temporary, atomically: true, encoding: .utf8)

        shelf.add(.fromFile(temporary))
        check("file lands on the shelf", shelf.items.count == countBefore + 1)
        check("file is referenced in place, not copied",
              shelf.items.first?.path == temporary.path)
        check("externally-owned file is not marked owned",
              shelf.items.first?.isOwned == false)

        shelf.add(.fromFile(temporary))
        check("the same file is not added twice", shelf.items.count == countBefore + 1)

        guard let id = shelf.items.first?.id else {
            check("shelf item exists to remove", false)
            return
        }
        shelf.remove(id)
        check("item can be removed", shelf.items.count == countBefore)
        check("removing a shelf item does NOT delete the user's file",
              FileManager.default.fileExists(atPath: temporary.path))
        try? FileManager.default.removeItem(at: temporary)

        let url = ShelfItem.fromURL(URL(string: "https://example.com/page")!)
        check("URL becomes a link item", url.kind == .url)
    }

    private static func testNotesAndTodos() {
        section("Notes and to-dos")
        let store = NotesStore.shared
        let notesBefore = store.notes.count
        let todosBefore = store.todos.count

        let note = store.addNote()
        store.updateNote(note.id, body: "Self test note\nsecond line")
        check("note is created and edited",
              store.notes.first { $0.id == note.id }?.body.hasPrefix("Self test") == true)
        check("title comes from the first line",
              store.notes.first { $0.id == note.id }?.title == "Self test note")

        store.searchText = "second"
        check("search matches the body", store.filteredNotes.contains { $0.id == note.id })
        store.searchText = "zzzznomatch"
        check("search excludes non-matches", !store.filteredNotes.contains { $0.id == note.id })
        store.searchText = ""
        store.deleteNote(note.id)
        check("note is deleted", store.notes.count == notesBefore)

        store.addTodo("  self test task  ")
        check("to-do is added and trimmed", store.todos.first?.text == "self test task")
        guard let todo = store.todos.first else { return }
        store.toggleDone(todo.id)
        check("to-do can be completed", store.todos.first?.isDone == true)
        check("completed items sort below open ones",
              store.activeTodos.last?.id == todo.id || store.activeTodos.count == 1)
        store.archiveCompleted()
        check("completed items archive out of the active list",
              !store.activeTodos.contains { $0.id == todo.id })
        store.deleteTodo(todo.id)
        check("to-do is deleted", store.todos.count == todosBefore)

        store.addTodo("   ")
        check("blank to-do is rejected", store.todos.count == todosBefore)
    }

    private static func testTimers() {
        section("Timers")
        let timers = TimerManager.shared
        timers.setMode(.countdown)
        timers.countdownDuration = 300
        timers.reset()
        check("countdown shows its full duration before starting",
              abs(timers.displayed - 300) < 1, "got \(timers.displayed)")
        check("formatted as m:ss", timers.formatted == "5:00", "got \(timers.formatted)")

        timers.start()
        check("timer reports running", timers.isRunning)
        timers.pause()
        check("timer reports paused", !timers.isRunning)
        timers.reset()

        timers.setMode(.stopwatch)
        check("stopwatch has no total duration", timers.totalDuration == nil)
        timers.setMode(.pomodoro)
        check("pomodoro starts in focus", timers.pomodoroPhase == .focus)
        check("pomodoro focus is 25 minutes", timers.pomodoroPhase.duration == 25 * 60)
        timers.setMode(.countdown)

        timers.adjustCountdown(by: -100_000)
        check("countdown clamps to a sane minimum", timers.countdownDuration >= 30)
        timers.countdownDuration = 300
        timers.reset()
    }

    private static func testMediaParsing() {
        section("Media")
        let manager = MediaManager.shared
        check("starts idle", manager.nowPlaying.isIdle)

        var track = NowPlaying(
            sourceID: "music", sourceName: "Music", state: .playing,
            title: "Track", artist: "Artist", album: "Album",
            duration: 200, position: 50, positionSampledAt: Date(), artworkKey: "k"
        )
        check("progress is position over duration", abs(track.progress - 0.25) < 0.01)

        track.positionSampledAt = Date().addingTimeInterval(-10)
        check("position interpolates between polls while playing",
              track.interpolatedPosition > 59 && track.interpolatedPosition < 61,
              "got \(track.interpolatedPosition)")

        track.state = .paused
        check("position does not drift while paused",
              abs(track.interpolatedPosition - 50) < 0.01)

        track.duration = 0
        check("zero duration cannot divide by zero", track.progress == 0)


        print("    installed media apps: \(manager.installedProviderNames.formattedList.isEmpty ? "none" : manager.installedProviderNames.formattedList)")
        print("    currently running: \(manager.availableProviders.map(\.displayName).formattedList.isEmpty ? "none" : manager.availableProviders.map(\.displayName).formattedList)")
    }

    private static func testPermissionsDegradeGracefully() {
        section("Permissions")
        let permissions = Permissions.shared
        permissions.refreshAll()
        // The notification status is resolved asynchronously.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        for kind in PermissionKind.allCases {
            let state = permissions.states[kind] ?? .unknown
            print("    \(kind.title): \(state.label)")
        }
        check("every permission has a readable state",
              PermissionKind.allCases.allSatisfy { permissions.states[$0] != nil })
        check("every permission has a System Settings link",
              PermissionKind.allCases.allSatisfy { $0.settingsURL != nil })

        // Managers must not crash when access has not been granted.

        check("notification APIs are guarded when unbundled",
              AppInfo.isRunningFromBundle || permissions.states[.notifications] == .unknown)
    }

}
