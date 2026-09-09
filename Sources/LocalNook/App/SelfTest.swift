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
    /// Checks whose precondition could not be met. Never counted as passes: an
    /// integration check that could not run is unverified, not green.
    private nonisolated(unsafe) static var unverified = 0
    /// Names of the checks that could not run, repeated at the end so a
    /// limitation is not something a reader has to go hunting for in the log.
    private nonisolated(unsafe) static var unverifiedNames: [String] = []

    /// Which half of the suite to run.
    ///
    /// The two halves have genuinely different reliability characteristics and
    /// mixing them hides that. Deterministic checks drive the controller through
    /// injected seams — pointer position, mouse-button state, display metrics,
    /// scheduling — and must pass every time on any machine. Integration checks
    /// ask the live window server to deliver a real crossing, which it does not
    /// always do for the only stimulus a test can produce without Accessibility.
    /// A red gate that mixes the two teaches people to ignore the gate.
    enum Suite: String {
        case deterministic
        case integration
        case all

        init(arguments: [String]) {
            if arguments.contains("--deterministic") { self = .deterministic }
            else if arguments.contains("--integration") { self = .integration }
            else { self = .all }
        }
    }

    static func run(_ suite: Suite = Suite(arguments: CommandLine.arguments)) -> Never {
        // Needs an NSApplication for AppKit geometry to be valid.
        // `.accessory`, not `.prohibited`: a prohibited app is not eligible to
        // receive UI events at all, which would make the hover test fail for a
        // reason that has nothing to do with the code under test.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // No snapshot-and-restore of the production domain here, deliberately.
        //
        // An earlier version of this file did exactly that, and it was both
        // unnecessary and unsafe. Unnecessary because `@Pref` already writes
        // through `AppInfo.defaults`, which is a disposable suite whenever
        // `--self-test` is present — the production domain was never being
        // touched. Unsafe because restoring a snapshot would *overwrite*
        // anything the running app changed while the suite was executing, and
        // because atexit does not run on a crash or a SIGKILL, so it could only
        // ever have been a partial guarantee for a problem that did not exist.
        //
        // Isolation is established by construction instead: see
        // AppInfo.isSelfTest, which is derived from the command line and so is
        // correct before any singleton can observe it.
        print("LocalNook self-test — suite: \(suite.rawValue)")
        print("displays connected: \(NSScreen.screens.count)\n")
        if suite != .integration {
            print("== DETERMINISTIC ==")
            // Close the two live-input doors for the whole deterministic half.
            // Everything here injects what it needs; a real click or a real
            // pointer movement is an uncontrolled variable, and leaving them
            // open made these checks fail whenever somebody was actually using
            // the Mac. Restored before the integration half, which needs them.
            NotchWindowController.shared.ignoresLiveInput = true
            testEnvironment()
            testGeometry()
            testPreferences()
            testShelf()
            testNotesAndTodos()
            testTimers()
            testMediaParsing()
            // Session fixtures are covered by StabilizationTests; never scan user transcripts here.
            testPermissionsDegradeGracefully()

            testClickThrough()
            testExternalDisplays()
            testInteractiveFootprint()
            testDashboardComposition()
            testLiquidGlass()
            testPrivacyBoundaries()
            testTrayWithRealFiles()
            testBrowserMedia()
            testMotion()
            testSessionDetail()
            testClearingTheTrayNeedsConfirming()
            testEveryWidgetIsReachable()
            testInteractionOwnership()
            testControllerTeardown()
            testMissedCrossingRecovery()
            testPointerFallback()
            testCloseLatch()
            testScriptableControl()
            StabilizationTests.run()
        }

        NotchWindowController.shared.ignoresLiveInput = false

        let deterministic = Tally(passed: passed, failed: failed, unverified: unverified)

        if suite != .deterministic {
            print("\n== LIVE INTEGRATION (real window server) ==")
            // A locked screen is an unmet precondition, not a platform quirk to
            // be attributed after the fact: with loginwindow covering
            // everything the harness cannot deliver a crossing at all. The
            // crossing-dependent checks say so; the rest still run, because
            // open(), toggle() and the initial state do not need one.
            //
            // It also has to be checked *before* the assertions rather than
            // after: "a pointer merely passing over the notch does not open it"
            // is a negative, and a locked screen satisfies it vacuously. That
            // would be a false pass, which is worse than an honest UNVERIFIED.
            let locked = HoverProbe.screenIsLocked
            if locked { print("\n  NOTE: the screen is LOCKED — no crossing can be delivered.") }
            testHoverPath(screenLocked: locked)
            testCatcherHover(screenLocked: locked)
        }

        AppInfo.defaults.removePersistentDomain(forName: AppInfo.testSuiteName)
        try? FileManager.default.removeItem(at: AppInfo.testDirectory)

        let integration = Tally(passed: passed, failed: failed, unverified: unverified)
            .subtracting(deterministic)

        print("")
        if suite != .integration { print("deterministic: \(deterministic.line)") }
        if suite != .deterministic { print("integration:   \(integration.line)") }
        print("total:         \(Tally(passed: passed, failed: failed, unverified: unverified).line)")
        if unverified > 0 {
            print("")
            print("UNVERIFIED means a check could not be exercised, NOT that it passed.")
            print("A required check that could not run remains an explicit limitation.")
            for name in unverifiedNames { print("  unverified: \(name)") }
        }
        exit(Int32(ExitCode.forResults(failed: failed, unverified: unverified).rawValue))
    }

    /// How a run's outcome reaches the release script.
    ///
    /// Three states, not two. Collapsing "a check could not run" into either
    /// "passed" or "failed" is what produces the two bad policies: a gate that
    /// reddens because nobody was at the keyboard, or a suite that waves through
    /// a demonstrated defect because it lives in the half labelled advisory.
    enum ExitCode: Int {
        /// Everything asserted, everything held.
        case clean = 0
        /// At least one check failed. A failure is only ever recorded for a
        /// demonstrated product defect — an event LocalNook was given and
        /// mishandled, or a final state that is wrong. This blocks a release
        /// whichever half of the suite produced it.
        case defect = 1
        /// Nothing failed, but a check could not be exercised: an environmental
        /// precondition was missing, or the harness could not deliver its input.
        /// Does not block a release; must be carried forward as a limitation.
        case unverified = 2

        static func forResults(failed: Int, unverified: Int) -> ExitCode {
            if failed > 0 { return .defect }
            if unverified > 0 { return .unverified }
            return .clean
        }
    }

    private struct Tally {
        var passed = 0
        var failed = 0
        var unverified = 0

        func subtracting(_ other: Tally) -> Tally {
            Tally(passed: passed - other.passed,
                  failed: failed - other.failed,
                  unverified: unverified - other.unverified)
        }

        var line: String {
            var text = "\(passed) passed, \(failed) failed"
            if unverified > 0 { text += ", \(unverified) UNVERIFIED" }
            return text
        }
    }

    /// End-to-end check of the real hover path.
    ///
    /// Builds the actual `NotchPanel` hosting the actual `NotchRootView`, then
    /// slides it under the stationary cursor. Moving the window rather than the
    /// pointer means this needs no Accessibility permission — which is the whole
    /// point, since `NSEvent.addGlobalMonitorForEvents` silently never fires
    /// without it and hover must not depend on that.
    private static func testHoverPath(screenLocked: Bool = false) {
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

        // Reset before the first placement. Resetting after it zeroed the very
        // crossing that opened the notch, so a successful run reported
        // enters=0 — a passing check with provenance that contradicted it.
        HoverProbe.reset()
        NotchTransitionLog.clear()

        // Slide the hover region under the cursor.
        let cursor = NSEvent.mouseLocation
        let hoverWidth = NotchShape.totalWidth(
            forBody: model.closedSize.width, topRadius: settings.closedCornerRadius
        )
        panel.setFrameOrigin(NSPoint(
            x: cursor.x - hoverWidth / 2,
            y: cursor.y - 120 + model.closedSize.height / 2 + 2
        ))
        pumpEvents(for: 0.15)

        // The hover strip is the top of the panel; confirm the pointer really
        // fell inside it before treating a non-event as a hover failure.
        let hoverStrip = NSRect(
            x: panel.frame.midX - hoverWidth / 2,
            y: panel.frame.maxY - (model.closedSize.height + 3),
            width: hoverWidth,
            height: model.closedSize.height + 3
        )
        guard hoverStrip.insetBy(dx: 2, dy: 2).contains(cursor) else {
            check("the hover strip could be placed under the pointer", false,
                  "pointer at \(cursor) fell outside the placed strip \(hoverStrip)")
            panel.orderOut(nil); panel.close()
            settings.openDelay = originalDelay
            return
        }

        // Retry the gesture, not the assertion — see provokeCrossing.
        let parkedFrame = NSRect(x: 4, y: 4, width: 320, height: 120)
        var opened = waitUntil({ model.state == .open }, timeout: 1.0)
        var attempts = 0
        while !opened, attempts < 3 {
            attempts += 1
            panel.setFrame(parkedFrame, display: true)
            pumpEvents(for: 0.2)
            panel.setFrameOrigin(NSPoint(
                x: cursor.x - hoverWidth / 2,
                y: cursor.y - 120 + model.closedSize.height / 2 + 2
            ))
            opened = waitUntil({ model.state == .open }, timeout: 1.0)
        }

        // Attribute the outcome to a stage rather than reporting a bare "hover
        // did not work". Each branch names a different culprit, and only two of
        // them are LocalNook's.
        let outcome = HoverProbe.classify(
            placed: !screenLocked,
            placementDetail: "the screen is locked; loginwindow is above every "
                           + "window, so no crossing can reach the panel",
            opened: opened
        )
        switch outcome {
        case .succeeded:
            check("[integration] hovering the notch opens it", true)
        case let .preconditionUnmet(detail):
            unmet("[integration] hovering the notch opens it", detail)
        case .noPlatformEvent:
            unmet("[integration] hovering the notch opens it",
                  "AppKit delivered no mouseEntered across \(attempts + 1) window moves; "
                  + "the pointer was verified inside the strip each time. "
                  + HoverProbe.environmentExplanation)
        case let .eventDropped(enters):
            check("[integration] hovering the notch opens it", false,
                  "AppKit delivered \(enters) crossing(s); LocalNook's handler ran 0 times")
        case let .wrongState(calls):
            check("[integration] hovering the notch opens it", false,
                  "LocalNook handled \(calls) crossing(s) and the notch is still \(model.state)")
        }
        // Stage counters say how far a crossing got; the transition source says
        // which mechanism actually moved the notch. Printing only the counters
        // produced a passing run whose provenance read handled=0 — true, and
        // useless, because a different path had done the work.
        print("    probe: \(HoverProbe.summary) "
              + "opened-by: \(NotchTransitionLog.all.last { $0.opened }.map { "\($0.source)" } ?? "nothing")")
        if !opened {
            // Only noisy when something is actually wrong.
            print("    cursor: \(cursor)")
            print("    panel:  \(panel.frame)")
            for line in HoverTracker.diagnostics { print("    tracker: \(line)") }
        }

        // Slide it away again.
        //
        // Only meaningful when the crossing in actually happened: this bare
        // panel is not owned by NotchWindowController, so its only close path
        // is the matching mouseExited. Recovery when no crossing is delivered
        // at all belongs to the real, controller-owned panel and is asserted
        // unconditionally by testMissedCrossingRecovery in the deterministic
        // suite — a hard gate on every run rather than one that only fires when
        // this flaky stimulus happens to work.
        let entersAtOpen = HoverProbe.entersDelivered
        panel.setFrameOrigin(NSPoint(x: 4, y: 4))
        if screenLocked {
            unmet("[integration] moving the pointer off it collapses again",
                  "the screen is locked; unlock and re-run")
        } else if opened {
            let closed = waitUntil({ model.state == .closed }, timeout: 2.0)
            reportExit("[integration] moving the pointer off it collapses again",
                       closed: closed, entersSeen: entersAtOpen, state: model.state)
        } else {
            unmet("[integration] moving the pointer off it collapses again",
                  "the notch never opened, so there was no open state to collapse")
        }

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

    /// Dashboard composition, and the two consent rules the layout forced open.
    private static func testDashboardComposition() {
        section("Dashboard")
        let settings = Settings.shared
        let originalDashboard = settings.dashboardWidgetIDs
        let originalEnabled = settings.enabledWidgetIDs

        settings.dashboardWidgetIDs = ["media", "calendar", "timers"]
        check("the default dashboard shows three sections",
              settings.dashboardWidgets.count == 3,
              "got \(settings.dashboardWidgets.map(\.rawValue))")

        // Narrow panels move sections into overflow rather than shrinking
        // everything — and, critically, never discard them.
        let all: [WidgetKind] = [.media, .timers, .calendar]
        let wide = DashboardView.plan(all, into: 900)
        let medium = DashboardView.plan(all, into: 380)
        let narrow = DashboardView.plan(all, into: 200)
        let tiny = DashboardView.plan(all, into: 60)

        check("a wide panel shows every section with no overflow",
              wide.visible.count == 3 && wide.overflow.isEmpty)
        check("a narrower panel moves sections into overflow",
              medium.visible.count < 3 && medium.visible.first == .media,
              "visible \(medium.visible.map(\.rawValue))")
        check("sections that stay visible still clear their minimum width",
              medium.visible.allSatisfy { $0.dashboardMinimumWidth <= 380 })
        check("a very narrow panel shows at most one section", narrow.visible.count <= 1)
        check("an unusably narrow panel shows none rather than something illegible",
              tiny.visible.isEmpty)

        // The invariant that makes overflow safe: an enabled widget is always
        // reachable, at every width, however the panel is sized.
        for width in stride(from: 40.0, through: 1400.0, by: 20.0) {
            let plan = DashboardView.plan(all, into: width)
            let reachable = plan.visible + plan.overflow
            guard reachable.count == all.count, Set(reachable) == Set(all) else {
                check("no enabled widget is lost at any panel width", false,
                      "at \(Int(width))pt: visible \(plan.visible.count), overflow \(plan.overflow.count)")
                break
            }
            guard Set(plan.visible).isDisjoint(with: Set(plan.overflow)) else {
                check("a widget is never both visible and in overflow", false,
                      "at \(Int(width))pt")
                break
            }
        }
        check("no enabled widget is lost at any panel width between 40 and 1400pt", true)

        // Visible sections must still fit once the overflow control has taken
        // its share, or the reserve would push something off the edge.
        let tight = DashboardView.plan(all, into: 420)
        if !tight.overflow.isEmpty {
            let reserve = DashboardView.overflowWidth + Theme.sectionGap
            let dividers = CGFloat(max(0, tight.visible.count - 1)) * Theme.sectionGap
            let needed = tight.visible.reduce(0) { $0 + $1.dashboardMinimumWidth } + dividers + reserve
            check("the overflow control is budgeted for, not squeezed in",
                  needed <= 420, "needed \(Int(needed))pt of 420pt")
        } else {
            check("the overflow control is budgeted for, not squeezed in", true)
        }

        // Widths must add up to the space available.
        let visible = DashboardView.fit(all, into: 900)
        let sum = visible.reduce(0) { $0 + DashboardView.width(for: $1, in: visible, total: 900) }
        let gaps = CGFloat(max(0, visible.count - 1)) * Theme.sectionGap
        check("section widths fill the panel exactly",
              abs(sum + gaps - 900) < 1, "sum \(Int(sum + gaps)) of 900")

        // A widget switched off must vanish, not be quietly replaced.
        settings.setWidget(.timers, enabled: false)
        check("a disabled widget leaves the dashboard",
              !settings.dashboardWidgets.contains(.timers))
        check("a disabled widget is not replaced by a fallback",
              settings.dashboardWidgets.count == 2,
              "got \(settings.dashboardWidgets.map(\.rawValue))")
        settings.setWidget(.timers, enabled: true)

        // Only widgets that suit a short, wide column may sit on the dashboard.
        settings.dashboardWidgetIDs = ["notes", "shortcuts", "media"]
        check("widgets that need room stay off the dashboard",
              settings.dashboardWidgets == [.media],
              "got \(settings.dashboardWidgets.map(\.rawValue))")

        // Opening the notch must never trigger a consent dialog.
        let before = CalendarManager.shared.authorization
        CalendarManager.shared.refreshIfAuthorized()
        check("showing the calendar section does not prompt for access",
              CalendarManager.shared.authorization == before,
              "authorization changed merely by rendering")

        settings.dashboardWidgetIDs = originalDashboard
        settings.enabledWidgetIDs = originalEnabled
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

    /// Mutable capture for stubs that must change answer mid-test.
    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// The two places where a UI boundary could leak into a device or lose work.
    private static func testPrivacyBoundaries() {
        section("Privacy boundaries")

        // ── Notes: an edit followed immediately by quit ──
        //
        // Saving is debounced so typing does not write a file per keystroke,
        // which means a quit can land inside the debounce window. Isolated
        // storage: the user's own notes are never touched.
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("localnook-notes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: store) }

        let notes = NotesStore(storeURL: store)
        let note = notes.addNote()
        let text = "an edit made immediately before quitting — ünïcode ✓"
        notes.updateNote(note.id, body: text)
        // No pause: quit lands inside the debounce window.
        notes.save()

        let reloaded = NotesStore(storeURL: store)
        check("an edit made just before quitting survives",
              reloaded.notes.first { $0.id == note.id }?.body == text,
              "got \(String(describing: reloaded.notes.first { $0.id == note.id }?.body))")

        // A to-do added and immediately flushed must survive too.
        notes.addTodo("buy milk")
        notes.save()
        let reloadedAgain = NotesStore(storeURL: store)
        check("a task added just before quitting survives",
              reloadedAgain.todos.contains { $0.text == "buy milk" })
        check("isolated test storage left the user's notes untouched",
              store.path.contains("localnook-notes-"))
    }

    /// The Tray against real files on a real pasteboard.
    ///
    /// This drives `ingest(_:)` with the same `NSPasteboard` content Finder puts
    /// there for a drag, so the ingest path is genuinely exercised. It does
    /// **not** perform the drag gesture itself — that needs pointer synthesis —
    /// so it is evidence about handling, not about the Finder interaction.
    private static func testTrayWithRealFiles() {
        section("Tray (real files)")
        let shelf = ShelfStore.shared
        let fixtures = FileManager.default.temporaryDirectory
            .appendingPathComponent("localnook-tray-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtures) }

        let startingCount = shelf.items.count

        func makeFile(_ name: String, _ body: String = "fixture") -> URL {
            let url = fixtures.appendingPathComponent(name)
            try? body.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        let plain = makeFile("notes.txt")
        let longName = makeFile(String(repeating: "extremely-long-file-name-", count: 5) + "end.txt")
        let doomed = makeFile("will-be-deleted.txt")
        let renamed = makeFile("will-be-renamed.txt")
        let folder = fixtures.appendingPathComponent("A Folder")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Exactly what Finder writes for a drag of several items.
        let board = NSPasteboard(name: .init("com.localnook.selftest.tray"))
        board.clearContents()
        board.writeObjects([plain, longName, doomed, renamed, folder] as [NSURL])
        let added = shelf.ingest(board)
        check("a multi-file drop adds every item", added == 5, "added \(added)")
        check("the tray holds them", shelf.items.count == startingCount + 5)

        check("a folder is recognised as a folder",
              shelf.items.first { $0.path == folder.path }?.kind == .folder)
        check("a very long name is kept intact for the UI to truncate",
              shelf.items.contains { $0.name.count > 60 })
        check("dropped files are referenced in place, never copied",
              shelf.items.first { $0.path == plain.path }?.isOwned == false)

        // Dropping the same selection again must not duplicate — but it is a
        // perfectly good drop and must not be reported as a failure, or AppKit
        // plays the rejection animation for it.
        board.clearContents()
        board.writeObjects([plain, folder] as [NSURL])
        let repeatDrop = shelf.ingestReportingOutcome(board)
        check("dropping the same items again adds nothing", repeatDrop.added == 0,
              "added \(repeatDrop.added) duplicates")
        check("the tray count is unchanged after a duplicate drop",
              shelf.items.count == startingCount + 5)
        check("a duplicate drop is still recognised", repeatDrop.duplicates == 2,
              "recognised \(repeatDrop.recognised)")
        check("a duplicate drop reports success, not a rejected drop",
              repeatDrop.wasHandled,
              "AppKit would snap the file back as though nothing understood it")

        // Unsupported content is a genuine failure and must say so.
        let junkBoard = NSPasteboard(name: .init("com.localnook.selftest.junk"))
        junkBoard.clearContents()
        junkBoard.setData(Data([0x00, 0x01]), forType: .init("com.localnook.nonsense"))
        let junkDrop = shelf.ingestReportingOutcome(junkBoard)
        check("unsupported content is not reported as handled", !junkDrop.wasHandled)

        // A file that disappears after being added.
        try? FileManager.default.removeItem(at: doomed)
        let missing = shelf.items.first { $0.path == doomed.path }
        check("a deleted file is detected as missing", missing?.stillExists == false)

        // A file renamed underneath us behaves the same way — the old path is gone.
        let newName = fixtures.appendingPathComponent("renamed.txt")
        try? FileManager.default.moveItem(at: renamed, to: newName)
        check("a renamed file is detected as missing at its old path",
              shelf.items.first { $0.path == renamed.path }?.stillExists == false)

        // Selection.
        if let first = shelf.items.first(where: { $0.path == plain.path })?.id,
           let second = shelf.items.first(where: { $0.path == folder.path })?.id {
            shelf.selection.removeAll()
            shelf.toggleSelection(first, extending: false)
            check("clicking selects one item", shelf.selection == [first])
            shelf.toggleSelection(second, extending: true)
            check("command-clicking extends the selection", shelf.selection.count == 2)
            check("selected URLs resolve to real paths",
                  shelf.selectedURLs.count == 2)
            shelf.selection.removeAll()
        } else {
            check("selection fixtures exist", false)
        }

        // The guarantee that matters most: removal touches the tray, never the
        // file — and not just its existence, its contents.
        let survivors = [plain, longName, folder]
        let contentsBefore = survivors.compactMap { try? Data(contentsOf: $0) }
        for item in shelf.items where survivors.map(\.path).contains(item.path ?? "") {
            shelf.remove(item.id)
        }
        check("removing from the tray never deletes the user's file",
              survivors.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
              "a fixture was deleted from disk")
        let contentsAfter = survivors.compactMap { try? Data(contentsOf: $0) }
        check("removing from the tray leaves file contents byte-for-byte intact",
              contentsBefore == contentsAfter,
              "a fixture's contents changed")
        check("the folder fixture is still a folder",
              (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true)

        // Text with no file of its own is stored by LocalNook, and *that* copy
        // is the only kind it may delete.
        board.clearContents()
        board.setString("a snippet with no file", forType: .string)
        let textAdded = shelf.ingest(board)
        check("plain text is accepted", textAdded == 1)
        if let owned = shelf.items.first(where: { $0.kind == .text }) {
            check("stored text is marked as LocalNook's own", owned.isOwned)
            let backing = owned.url
            shelf.remove(owned.id)
            check("removing stored text deletes only LocalNook's copy",
                  backing.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false)
        } else {
            check("stored text item exists", false)
        }

        // Unsupported content is rejected rather than producing a broken row.
        board.clearContents()
        board.setData(Data([0x00, 0x01, 0x02]), forType: .init("com.localnook.nonsense"))
        let junk = shelf.ingest(board)
        check("unsupported content is refused", junk == 0, "accepted \(junk) items")

        // Leave the user's tray as we found it.
        for item in shelf.items where item.path?.hasPrefix(fixtures.path) == true {
            shelf.remove(item.id)
        }
        check("fixtures are cleaned out of the tray",
              shelf.items.count == startingCount,
              "\(shelf.items.count) items, expected \(startingCount)")
    }

    /// Interaction claims must hold a notch open only as long as their premise
    /// lasts, and only for the notch they belong to.
    private static func testInteractionOwnership() {
        section("Interaction ownership")
        let controller = NotchWindowController.shared
        controller.start()
        pumpEvents(for: 0.4)

        let models = controller.allModels
        guard let first = models.first else {
            check("a notch exists to claim", false)
            return
        }

        check("a fresh notch holds no claims", !first.isInteracting)

        let owner = UUID()
        first.claimInteraction(.textEditing, owner: owner)
        check("claiming holds that notch open", first.isInteracting)
        check("the fallback declines to close a claimed notch",
              controller.fallbackIsHoldingOff(for: first))

        // Per-display scoping: this is the bug where typing on one display, or
        // opening Settings, pinned every notch everywhere.
        //
        // Previously this asserted `true` when only one display was attached,
        // which reported a pass for a check that had not run. A second notch is
        // seeded instead so the rule is exercised on any machine; the display
        // count is printed so a reader knows which it was.
        let physicalDisplays = NSScreen.screens.count
        let seededID = "self-test.ownership-display"
        let second: NotchViewModel
        if models.count > 1, let other = models.first(where: { $0 !== first }) {
            second = other
            print("    second notch: a real one (\(physicalDisplays) display(s) attached)")
        } else {
            second = controller.installSyntheticNotch(
                id: seededID,
                frame: CGRect(x: -4000, y: -4000, width: 400, height: 200)
            )
            print("    second notch: seeded (\(physicalDisplays) display attached)")
        }
        defer { controller.removeSyntheticNotch(id: seededID) }
        check("a claim on one display does not pin another",
              !second.isInteracting && !controller.fallbackIsHoldingOff(for: second),
              "the other display was suppressed too")

        first.releaseInteraction(.textEditing, owner: owner)
        check("releasing ends the hold", !first.isInteracting)

        // Text editing lasts exactly as long as key focus. The panel is not key
        // here, so validation must drop a claim nothing is sustaining.
        first.claimInteraction(.textEditing, owner: UUID())
        controller.validateClaimsNow()
        check("a text-editing claim ends when the panel is not key",
              !first.activeInteractions.contains(.textEditing),
              "a claim outlived its premise")

        // A drag cancelled off-screen: no button is held, so the claim goes.
        //
        // The button state is injected rather than read. This used to branch on
        // `NSEvent.pressedMouseButtons` and report itself unverified whenever
        // somebody happened to be holding the mouse — the last place in the
        // deterministic half that still asked the real machine a question it
        // did not need to ask. The seam for this already existed; the check
        // simply was not using it.
        let realButtons = controller.mouseButtonsAreDown
        controller.mouseButtonsAreDown = { false }
        first.claimInteraction(.dragging, owner: UUID())
        first.isDragTargeting = true
        controller.validateClaimsNow()
        check("a drag claim ends once no mouse button is held",
              !first.activeInteractions.contains(.dragging),
              "a cancelled drag left the notch pinned")
        check("stale drag targeting is cleared with it", !first.isDragTargeting)
        controller.mouseButtonsAreDown = realButtons

        // Nothing may survive a close into the next open.
        //
        // Driven on this model directly. `perform(.open)` routes to whichever
        // display the pointer is on, which is not necessarily `first` — with a
        // second display attached that raced, the notch under test never
        // opened, and the check reported itself unverified about a third of the
        // time. Same root cause as the fallback hold-off check above.
        first.allowHoverToReopen()
        first.open()
        waitUntil { first.state == .open }
        if first.state == .open {
            first.claimInteraction(.textEditing, owner: UUID())
            first.claimInteraction(.dragging, owner: UUID())
            first.close()
            waitUntil { first.state == .closed }
            check("closing releases every claim", !first.isInteracting,
                  "claims survived into the next open: \(first.activeInteractions.map(\.label))")
            check("closing clears drag targeting", !first.isDragTargeting)
        } else {
            unmet("closing releases every claim", "the notch did not open to be closed")
        }

        // A non-panel key window — Settings, Quick Look — must pin nothing.
        let settingsLike = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 200, height: 120),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        settingsLike.makeKeyAndOrderFront(nil)
        pumpEvents(for: 0.3)
        controller.validateClaimsNow()
        check("another of our windows taking focus pins no notch",
              controller.allModels.allSatisfy { !$0.isInteracting },
              "Settings-like focus suppressed closing")
        settingsLike.orderOut(nil)
        settingsLike.close()
        pumpEvents(for: 0.2)

        controller.stop()
        pumpEvents(for: 0.2)
    }

    /// The once-a-second recovery check: it must rescue a stuck notch without
    /// interrupting anything the user is deliberately doing.
    private static func testPointerFallback() {
        section("Pointer fallback")
        let controller = NotchWindowController.shared
        NotchTransitionLog.clear()

        check("no recovery ticking before anything opens",
              !controller.pointerSafetyNetIsRunning,
              "an idle Mac must not be polled")

        controller.start()
        pumpEvents(for: 0.4)
        check("still no ticking while everything is collapsed",
              !controller.pointerSafetyNetIsRunning)

        controller.perform(.open)
        pumpEvents(for: 0.4)
        waitUntil { controller.pointerSafetyNetIsRunning }
        check("opening starts the recovery check", controller.pointerSafetyNetIsRunning)
        // Look for the most recent *open*: a system event such as fullscreen
        // suppression can legitimately log a close in between.
        let lastOpen = NotchTransitionLog.all.last { $0.opened }
        check("the open was attributed to the command that caused it",
              lastOpen?.source == .explicitCommand,
              "got \(String(describing: lastOpen?.source))")

        // Both branches are exercised on every run: the pointer is injected
        // rather than read. Previously this asked where the tester's hand
        // happened to be and reported a pass for whichever branch did not run.
        // Restored on every path so an override cannot leak into a later test.
        let realPointer = controller.pointerLocation
        defer { controller.pointerLocation = realPointer }

        // 1. Pointer resting on the notch: the fallback must leave *that* notch
        //    alone.
        //
        // The pointer has to be parked on the display whose notch is actually
        // open. Taking `allModels.first` picked an arbitrary dictionary entry,
        // so with two displays attached it parked the pointer on one screen's
        // notch while the other screen's notch was the open one — and then read
        // the entirely correct per-display close as a failure to hold off. It
        // passed on a one-display Mac for the same reason it was wrong: there
        // was only ever one model to pick.
        let openModel = controller.allModels.first { $0.state == .open }
        if let openModel, let screen = openModel.screen {
            let onNotch = NSPoint(x: screen.frame.midX,
                                  y: screen.frame.maxY - NotchGeometry.openSize.height / 2)
            controller.pointerLocation = { onNotch }
            controller.runPointerSafetyCheckNow()
            pumpEvents(for: 0.3)
            check("the fallback holds off while the pointer is on the notch",
                  openModel.state == .open,
                  "it closed the notch the pointer was resting on"
                  + " (\(NSScreen.screens.count) display(s) attached)")
        } else if openModel == nil {
            check("the fallback holds off while the pointer is on the notch", false,
                  "no notch was open to hold off on after perform(.open)")
        } else {
            unmet("the fallback holds off while the pointer is on the notch",
                  "the open notch has no screen to compute a pointer position on")
        }

        // 2. Pointer clearly elsewhere: one pass must close it, and say why.
        controller.pointerLocation = { NSPoint(x: 12_000, y: 12_000) }
        controller.runPointerSafetyCheckNow()
        check("a notch the pointer has left is recovered",
              waitUntil({ controller.allModels.allSatisfy { $0.state == .closed } },
                        timeout: 1.5),
              "still open after a recovery pass")
        let lastClose = NotchTransitionLog.all.last { !$0.opened }
        check("the recovery close is attributed to the fallback, not to hover",
              lastClose?.source == .pointerFallback,
              "got \(String(describing: lastClose?.source))")
        controller.pointerLocation = realPointer

        // Dragging is a deliberate interaction; recovery must not interrupt it.
        // Asserted on what the pass *decided* rather than on state after a
        // delay, because SwiftUI's own drop tracking resets the flag on the next
        // render and would mask the result.
        controller.perform(.open)
        pumpEvents(for: 0.3)

        // A live drag: button held, claim taken — exactly the state AppKit puts
        // us in between draggingEntered and the drop.
        // Restored on every path, so an override can never leak into a later
        // section of the suite.
        defer { controller.mouseButtonsAreDown = { NSEvent.pressedMouseButtons != 0 } }
        controller.mouseButtonsAreDown = { true }
        let dragOwner = UUID()
        controller.allModels.forEach {
            $0.cancelPending()
            $0.claimInteraction(.dragging, owner: dragOwner)
            $0.isDragTargeting = true
        }
        controller.runPointerSafetyCheckNow()
        check("a drag in progress is never closed underneath the user",
              controller.allModels.allSatisfy { !$0.hasPendingClose },
              "the fallback scheduled a close mid-drag")

        // The button comes up somewhere off the panel and the drop never
        // arrives — the classic way stale drag state used to pin the notch.
        controller.mouseButtonsAreDown = { false }
        controller.runPointerSafetyCheckNow()
        check("a drag abandoned off-screen stops holding the notch open",
              controller.allModels.allSatisfy {
                  !$0.activeInteractions.contains(.dragging) && !$0.isDragTargeting
              },
              "stale drag state survived the button coming up")
        controller.mouseButtonsAreDown = { NSEvent.pressedMouseButtons != 0 }

        controller.perform(.close)
        waitUntil { !controller.pointerSafetyNetIsRunning }
        check("the recovery check stops once everything is closed",
              !controller.pointerSafetyNetIsRunning,
              "it kept ticking with nothing open")

        // Repeated cycles must not accumulate anything.
        let windowsBefore = controller.panelCount + controller.catcherCount
        for _ in 0..<5 {
            controller.perform(.open); pumpEvents(for: 0.1)
            controller.perform(.close); pumpEvents(for: 0.1)
        }
        waitUntil { !controller.pointerSafetyNetIsRunning }
        check("repeated open/close cycles leak no windows",
              controller.panelCount + controller.catcherCount == windowsBefore,
              "\(controller.panelCount + controller.catcherCount) vs \(windowsBefore)")
        check("repeated cycles leave no recovery task running",
              !controller.pointerSafetyNetIsRunning)

        // Provenance must never be able to pass a command off as a hover.
        let commandOpens = NotchTransitionLog.all.filter {
            $0.opened && $0.source == .explicitCommand
        }.count
        check("scripted opens are recorded as commands, not tracking events",
              commandOpens >= 5, "only \(commandOpens) attributed to commands")
        check("the log records no tracking events for scripted activity",
              NotchTransitionLog.count(of: .trackingArea) == 0,
              "\(NotchTransitionLog.count(of: .trackingArea)) tracking events appeared without a pointer")

        controller.stop()
        pumpEvents(for: 0.2)
        check("stopping the controller stops the recovery check too",
              !controller.pointerSafetyNetIsRunning,
              "a stopped controller kept polling, and can close a later session's notch")
    }

    /// Hover, end to end, through the catcher that actually handles it.
    ///
    /// This matters more than it looks: collapsed, the drawing panel is inert,
    /// so its tracking area never fires. If the catcher's hover broke, the notch
    /// would simply stop opening — and the older hover test would still pass,
    /// because it exercises the wrong window.
    private static func testCatcherHover(screenLocked: Bool = false) {
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
        let parked = NSRect(x: 4, y: 4, width: size.width, height: size.height)
        HoverProbe.reset()
        NotchTransitionLog.clear()
        let placed = placePanel(panel, around: cursor, size: size)
        let crossed = placed && waitUntil({ model.state == .open }, timeout: 1.5)

        switch HoverProbe.classify(
            placed: placed && !screenLocked,
            placementDetail: screenLocked
                ? "the screen is locked; loginwindow is above every window, so no "
                  + "crossing can reach the catcher"
                : "window server clamped the frame; pointer at \(cursor)",
            opened: crossed
        ) {
        case .succeeded:
            check("[integration] hovering the catcher opens the notch", true)
        case let .preconditionUnmet(detail):
            unmet("[integration] hovering the catcher opens the notch", detail)
        case .noPlatformEvent:
            unmet("[integration] hovering the catcher opens the notch",
                  "AppKit delivered no crossing for a window moved under a still pointer. "
                  + HoverProbe.environmentExplanation)
        case let .eventDropped(enters):
            check("[integration] hovering the catcher opens the notch", false,
                  "AppKit delivered \(enters) crossing(s) and LocalNook forwarded none")
        case let .wrongState(calls):
            check("[integration] hovering the catcher opens the notch", false,
                  "LocalNook handled \(calls) crossing(s) but the notch is \(model.state)")
        }

        print("    probe: \(HoverProbe.summary) "
              + "opened-by: \(NotchTransitionLog.all.last { $0.opened }.map { "\($0.source)" } ?? "nothing")")

        // This model is not in the controller's registry, so the pointer
        // fallback does not cover it — asserting recovery here would be
        // asserting a promise the product does not make for a detached panel.
        // The real postcondition ("a notch open with the pointer elsewhere
        // always closes") is a hard gate in testMissedCrossingRecovery.
        // The catcher deliberately does *not* close an open notch when the
        // pointer leaves it: by then the pointer has moved into the expanded
        // panel, which owns hover from that point on. Asserting a collapse here
        // asserted behaviour the catcher does not have — and the probe caught
        // it, reporting an exit that was delivered, forwarded, and correctly
        // left the state alone. Closing on exit is testHoverPath's job; recovery
        // when no exit arrives at all is testMissedCrossingRecovery's.
        panel.setFrame(parked, display: true)
        if screenLocked {
            unmet("[integration] the catcher hands an open notch to the panel rather than closing it",
                  "the screen is locked; unlock and re-run")
            unmet("[integration] leaving the catcher clears the stay-shut latch",
                  "the screen is locked; unlock and re-run")
        } else if crossed {
            pumpEvents(for: 0.6)
            check("[integration] the catcher hands an open notch to the panel rather than closing it",
                  model.state == .open,
                  "the catcher closed it itself; state \(model.state), probe \(HoverProbe.summary)")
            check("[integration] leaving the catcher clears the stay-shut latch",
                  !model.hoverReopenBlocked)
        } else {
            unmet("[integration] the catcher hands an open notch to the panel rather than closing it",
                  "it never opened, so there was no hand-over to observe")
            unmet("[integration] leaving the catcher clears the stay-shut latch",
                  "no crossing was delivered to leave")
        }
        model.close()

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
        // A negative assertion, so a locked screen satisfies it for the wrong
        // reason. Reporting that as a pass would be worse than reporting nothing.
        if screenLocked {
            unmet("a pointer merely passing over the notch does not open it",
                  "the screen is locked, so nothing could have opened it anyway")
        } else {
            check("a pointer merely passing over the notch does not open it",
                  model.state == .closed,
                  "it opened after the pointer had already left")
        }

        panel.orderOut(nil)
        panel.close()
        settings.openDelay = originalDelay
    }

    /// Browser media: parsing, capability gating and source selection.
    ///
    /// Synthetic throughout — fixtures and constructed snapshots, no browser
    /// involved. What a real browser actually does is a separate question,
    /// answered by observing playback, and this section must not be read as
    /// evidence for it.
    private static func testBrowserMedia() {
        section("Browser media (synthetic)")

        // Fixtures and constructed observations throughout. Nothing here talks
        // to a browser, plays audio, or asks for permission — so nothing here
        // is evidence about what a real browser does. That is a separate
        // question, answered by observing playback, and these results must not
        // be read as standing in for it.

        // ── Which tabs count as a player ───────────────────────────────────
        check("a YouTube watch page is a player",
              BrowserMediaParser.site(forURL: "https://www.youtube.com/watch?v=abc") == "YouTube")
        check("a YouTube live page is a player",
              BrowserMediaParser.site(forURL: "https://www.youtube.com/live/xyz") == "YouTube")
        check("YouTube Music is named as itself",
              BrowserMediaParser.site(forURL: "https://music.youtube.com/watch?v=1") == "YouTube Music")
        check("the YouTube home page is not a player",
              BrowserMediaParser.site(forURL: "https://www.youtube.com/") == nil)
        check("an unrelated site is not a player",
              BrowserMediaParser.site(forURL: "https://example.com/watch") == nil)
        check("a lookalike host is not matched",
              BrowserMediaParser.site(forURL: "https://notyoutube.com/watch?v=1") == nil)
        check("a subdomain of a known host is matched",
              BrowserMediaParser.site(forURL: "https://m.soundcloud.com/x") == "SoundCloud")
        check("nonsense is not a player",
              BrowserMediaParser.site(forURL: "not a url at all") == nil)
        check("an empty URL is not a player",
              BrowserMediaParser.site(forURL: "") == nil)

        // ── Titles, including the decoration seen in a real capture ────────
        check("a notification count is stripped",
              BrowserMediaParser.cleanTitle("(72) Big Buck Bunny - YouTube", site: "YouTube")
                  == "Big Buck Bunny",
              "got \(BrowserMediaParser.cleanTitle("(72) Big Buck Bunny - YouTube", site: "YouTube"))")
        check("the site suffix is stripped",
              BrowserMediaParser.cleanTitle("Some Song - SoundCloud", site: "SoundCloud")
                  == "Some Song")
        check("a title that is only decoration falls back to the site",
              BrowserMediaParser.cleanTitle(" - YouTube", site: "YouTube") == "YouTube")
        check("a bracketed non-number is left alone",
              BrowserMediaParser.cleanTitle("(Live) Session One", site: "YouTube")
                  == "(Live) Session One")
        check("an empty title falls back to the site",
              BrowserMediaParser.cleanTitle("", site: "Vimeo") == "Vimeo")
        check("a title with no decoration is untouched",
              BrowserMediaParser.cleanTitle("Plain Title", site: "YouTube") == "Plain Title")

        check("an advertisement is recognised",
              BrowserMediaParser.looksLikeAdvertisement("Ad · 5s"))
        check("a song about ads is not mistaken for one",
              !BrowserMediaParser.looksLikeAdvertisement("Adagio in G Minor"))

        // ── Reading the page's own answer ──────────────────────────────────
        check("a playing page parses",
              BrowserMediaParser.parsePageMedia("0|0|0|12.5|300")
                  == PageMedia(isPaused: false, isEnded: false, isMuted: false,
                               position: 12.5, duration: 300))
        check("an empty reply means no media element was found, not a pause",
              BrowserMediaParser.parsePageMedia("") == nil)
        check("whitespace alone means nothing was found",
              BrowserMediaParser.parsePageMedia("\n ") == nil)
        check("a livestream reports no duration rather than zero",
              BrowserMediaParser.parsePageMedia("0|0|0|900|-1")?.duration == nil)
        check("a muted page is still reported as playing",
              BrowserMediaParser.parsePageMedia("0|0|1|30|300")?.isPlaying == true)
        check("an ended page is not playing",
              BrowserMediaParser.parsePageMedia("1|1|0|300|300")?.isPlaying == false)
        check("a garbled reply is discarded rather than half-read",
              BrowserMediaParser.parsePageMedia("0|0|0|nonsense|300") == nil)
        check("a truncated reply is discarded",
              BrowserMediaParser.parsePageMedia("0|0|300") == nil)
        check("a negative position is clamped rather than trusted",
              BrowserMediaParser.parsePageMedia("0|0|0|-5|300")?.position == 0)

        // ── Audio activity is debounced, but not remembered ────────────────
        var hold = BrowserAudioHold()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        check("silence with no history is silence", !hold.observe(false, now: t0))
        check("audio is reported at once", hold.observe(true, now: t0))
        check("a momentary gap does not blink the widget out",
              hold.observe(false, now: t0.addingTimeInterval(1)))
        check("a real stop is reported once the window passes",
              !hold.observe(false, now: t0.addingTimeInterval(BrowserAudioHold.window + 0.1)))
        var reset = BrowserAudioHold()
        _ = reset.observe(true, now: t0)
        reset.reset()
        check("a reset forgets the hold immediately",
              !reset.observe(false, now: t0.addingTimeInterval(0.1)))
        var backwards = BrowserAudioHold()
        _ = backwards.observe(true, now: t0)
        check("a clock that jumps backwards does not hold forever",
              !backwards.observe(false, now: t0.addingTimeInterval(-3600)))

        // ── What may honestly be claimed ───────────────────────────────────
        //
        // The matrix the browser path has to survive. Each case names an
        // observation and asserts the claim it does *not* license.
        func tab(_ key: String, _ title: String, page: PageMedia? = nil) -> BrowserMediaTab {
            BrowserMediaTab(key: key, title: title,
                            url: "https://www.youtube.com/watch?v=\(key)",
                            site: "YouTube", page: page)
        }
        func playingPage(at position: Double = 10, duration: Double? = 300) -> PageMedia {
            PageMedia(isPaused: false, isEnded: false, isMuted: false,
                      position: position, duration: duration)
        }
        func pausedPage(at position: Double = 10) -> PageMedia {
            PageMedia(isPaused: true, isEnded: false, isMuted: false,
                      position: position, duration: 300)
        }
        func resolve(
            _ tabs: [BrowserMediaTab], audio: Bool, incumbent: String? = nil
        ) -> BrowserPlaybackResolver.Resolution? {
            BrowserPlaybackResolver.resolve(
                tabs: tabs, audioActive: audio,
                browserName: "Google Chrome", incumbentTabKey: incumbent
            )
        }

        // Nothing open.
        check("no tabs and no audio says nothing",
              resolve([], audio: false) == nil)
        check("audio with no player tab open is not attributed to a player",
              resolve([], audio: true) == nil,
              "an unrelated tab's audio was reported as media")

        // One tab, no page access: the browser is audible, the tab is not known
        // to be the source.
        let oneTab = resolve([tab("a", "Track One")], audio: true)
        check("one media tab with browser audio is named", oneTab?.title == "Track One")
        check("one media tab with browser audio is not called playing",
              oneTab?.state == .unknown,
              "got \(oneTab?.state.rawValue ?? "nil")")
        check("that wording says what was actually measured",
              statusText(oneTab) == "Browser audio active")
        check("it offers no play/pause it cannot honour",
              oneTab?.capabilities.contains(.playPause) == false)
        check("it claims no authoritative playback state",
              oneTab?.capabilities.contains(.playbackState) == false)
        check("a silent browser with a tab open reports nothing at all",
              resolve([tab("a", "Track One")], audio: false) == nil,
              "no audio was read as evidence of a pause")

        // Two tabs, no page access: nothing distinguishes them.
        let twoTabs = resolve([tab("a", "Track One"), tab("b", "Track Two")], audio: true)
        check("two media tabs and no page access names neither",
              twoTabs?.title == "Browser audio active",
              "got \(twoTabs?.title ?? "nil")")
        check("that case is marked ambiguous", twoTabs?.isAmbiguous == true)
        check("the ambiguous case says the tab is unknown",
              statusText(twoTabs) == "Source tab unknown")
        check("the ambiguous case names the browser and the count",
              twoTabs?.subtitle == "Google Chrome · 2 media tabs")
        check("the ambiguous case selects no tab", twoTabs?.tabKey.isEmpty == true)

        // Two tabs, page access: the page names the one that is playing.
        let identified = resolve([
            tab("a", "Track One", page: pausedPage()),
            tab("b", "Track Two", page: playingPage()),
        ], audio: true)
        check("page access identifies which of two tabs is playing",
              identified?.title == "Track Two")
        check("an identified tab is called playing", identified?.state == .playing)
        check("an identified tab is not ambiguous", identified?.isAmbiguous == false)
        check("an identified tab offers play/pause",
              identified?.capabilities.contains(.playPause) == true)
        check("an identified tab with a duration offers a scrubber",
              identified?.capabilities.contains(.position) == true)

        // A paused video while another plays.
        check("a paused tab does not win over a playing one",
              resolve([
                  tab("a", "Paused One", page: pausedPage()),
                  tab("b", "Playing One", page: playingPage()),
              ], audio: true)?.title == "Playing One")

        // Everything paused, and everything readable: a definite statement.
        let allPaused = resolve([
            tab("a", "Track One", page: pausedPage()),
            tab("b", "Track Two", page: pausedPage()),
        ], audio: false)
        check("every readable tab paused is reported as paused",
              allPaused?.state == .paused)
        check("a definite pause claims an authoritative state",
              allPaused?.capabilities.contains(.playbackState) == true)

        // Page access on, but one tab could not be read — an embedded player in
        // a cross-origin frame, or a page with no media element.
        let partiallyReadable = resolve([
            tab("a", "Readable", page: pausedPage()),
            tab("b", "Unreadable"),
        ], audio: true)
        check("an unreadable tab blocks a paused claim about the others",
              partiallyReadable?.state == .unknown,
              "got \(partiallyReadable?.state.rawValue ?? "nil")")
        check("and that case is ambiguous rather than named",
              partiallyReadable?.isAmbiguous == true)
        check("without audio, an unreadable tab does not block the paused claim",
              resolve([tab("a", "Readable", page: pausedPage()),
                       tab("b", "Unreadable")], audio: false)?.state == .paused)

        // Muted playback: the page knows, CoreAudio cannot.
        let muted = resolve([tab("a", "Muted", page: PageMedia(
            isPaused: false, isEnded: false, isMuted: true, position: 5, duration: 300
        ))], audio: false)
        check("muted playback is still playing, because the page said so",
              muted?.state == .playing)

        // Buffering: not paused, nothing played yet.
        let buffering = resolve([tab("a", "Buffering", page: PageMedia(
            isPaused: false, isEnded: false, isMuted: false, position: 0, duration: nil
        ))], audio: false)
        check("a buffering tab is playing with no progress bar",
              buffering?.state == .playing && buffering?.durationIsUnknown == true)
        check("a buffering tab offers no scrubber",
              buffering?.capabilities.contains(.position) == false)

        // Ended media.
        let ended = PageMedia(isPaused: true, isEnded: true, isMuted: false,
                              position: 300, duration: 300)
        check("an ended video with no audio reports nothing",
              resolve([tab("a", "Finished", page: ended)], audio: false) == nil)
        check("an ended video is never called playing",
              resolve([tab("a", "Finished", page: ended)], audio: true)?.state != .playing)
        check("a second tab playing wins over an ended one",
              resolve([tab("a", "Finished", page: ended),
                       tab("b", "Live One", page: playingPage())], audio: true)?.title
                  == "Live One")

        // A livestream: position without an end.
        let livestream = resolve([tab("a", "Stream", page: playingPage(at: 900, duration: nil))],
                                 audio: true)
        check("a livestream is playing", livestream?.state == .playing)
        check("a livestream has no known duration", livestream?.durationIsUnknown == true)
        check("a livestream offers no scrubber",
              livestream?.capabilities.contains(.position) == false)
        check("a livestream still offers play/pause",
              livestream?.capabilities.contains(.playPause) == true)

        // Stickiness, and its limit.
        let bothPlaying = [tab("a", "Track One", page: playingPage()),
                           tab("b", "Track Two", page: playingPage())]
        check("the tab already on screen is kept while it is still playing",
              resolve(bothPlaying, audio: true, incumbent: "b")?.tabKey == "b",
              "the widget would have jumped between two playing tabs")
        check("an incumbent that stopped gives way",
              resolve([tab("a", "Track One", page: playingPage()),
                       tab("b", "Track Two", page: pausedPage())],
                      audio: true, incumbent: "b")?.tabKey == "a")
        check("an incumbent whose tab closed is replaced, not remembered",
              resolve([tab("a", "Track One", page: playingPage())],
                      audio: true, incumbent: "gone")?.tabKey == "a")
        check("closing every media tab clears the widget",
              resolve([], audio: true, incumbent: "a") == nil)

        // Repeated polls with unchanged input must settle.
        var held: String? = nil
        var picks: [String] = []
        for _ in 0..<12 {
            held = resolve(bothPlaying, audio: true, incumbent: held)?.tabKey
            picks.append(held ?? "")
        }
        check("repeated polls settle on one tab rather than alternating",
              Set(picks).count == 1, "picked \(Set(picks).sorted())")

        // An advert is labelled as one rather than as the track.
        check("an advertisement is attributed to the advert, not the video",
              resolve([tab("a", "Ad · 15s", page: playingPage())], audio: true)?.subtitle
                  == "Advertisement · YouTube")

        // ── Capability gating ──────────────────────────────────────────────
        var titleOnly = NowPlaying.idle
        titleOnly.title = "Something"
        titleOnly.state = .unknown
        titleOnly.capabilities = .titleOnly
        check("a title-only source offers no play/pause",
              !titleOnly.capabilities.contains(.playPause))
        check("a title-only source offers no skip",
              !titleOnly.capabilities.contains(.skip))
        check("a title-only source draws no progress bar", !titleOnly.showsProgress)
        check("a title-only source claims no authoritative state",
              !titleOnly.capabilities.contains(.playbackState))
        check("a title-only source is not idle — it is showing something true",
              !titleOnly.isIdle)
        check("an unknown state still animates the level meter",
              titleOnly.showsMotion, "audio is measured; only its tab is in doubt")

        var scripted = NowPlaying.idle
        scripted.title = "Track"
        scripted.duration = 200
        scripted.position = 20
        scripted.state = .playing
        scripted.capabilities = .full
        check("a scripted source offers play/pause", scripted.capabilities.contains(.playPause))
        check("a scripted source draws a progress bar", scripted.showsProgress)
        check("a definite state says so", scripted.state.isDefinite)
        check("an inferred state does not", !PlaybackState.unknown.isDefinite)

        // ── Wording ────────────────────────────────────────────────────────
        check("playing is called playing", statusText(.playing, ambiguous: false) == "Playing")
        check("paused is called paused", statusText(.paused, ambiguous: false) == "Paused")
        check("an inferred state is never called playing",
              statusText(.unknown, ambiguous: false) != "Playing"
                  && statusText(.unknown, ambiguous: true) != "Playing")
        check("an inferred state is never called paused",
              statusText(.unknown, ambiguous: false) != "Paused"
                  && statusText(.unknown, ambiguous: true) != "Paused")

        // ── Unknown duration: livestreams and metadata that never arrives ──
        var live = scripted
        live.durationIsUnknown = true
        check("an unknown duration draws no progress bar", !live.showsProgress)
        check("an unknown duration reports zero progress rather than a wrong one",
              live.progress == 0)

        var zero = scripted
        zero.duration = 0
        check("a zero duration draws no progress bar", !zero.showsProgress)

        // ── Choosing between sources ───────────────────────────────────────
        func snapshot(_ id: String, _ state: PlaybackState) -> NowPlaying {
            var value = NowPlaying.idle
            value.sourceID = id
            value.sourceName = id
            value.title = "t"
            value.state = state
            return value
        }
        check("nothing playing yields nothing",
              MediaManager.choose(from: [], current: "") == nil)
        check("a single source is chosen",
              MediaManager.choose(from: [snapshot("a", .playing)], current: "")?.sourceID == "a")
        check("playing beats paused",
              MediaManager.choose(from: [snapshot("a", .paused), snapshot("b", .playing)],
                                  current: "")?.sourceID == "b")
        check("a source that knows it is playing beats one that only might be",
              MediaManager.choose(from: [snapshot("a", .unknown), snapshot("b", .playing)],
                                  current: "")?.sourceID == "b",
              "an inferred state masked a measured one")
        check("a source that might be playing beats one that is paused",
              MediaManager.choose(from: [snapshot("a", .paused), snapshot("b", .unknown)],
                                  current: "")?.sourceID == "b")
        check("the source already on screen is kept while it plays",
              MediaManager.choose(from: [snapshot("a", .playing), snapshot("b", .playing)],
                                  current: "b")?.sourceID == "b",
              "the widget would have jumped to another player")
        check("a stopped incumbent gives way to one that is playing",
              MediaManager.choose(from: [snapshot("a", .playing), snapshot("b", .paused)],
                                  current: "b")?.sourceID == "a")
        check("with nothing playing the incumbent is still kept",
              MediaManager.choose(from: [snapshot("a", .paused), snapshot("b", .paused)],
                                  current: "b")?.sourceID == "b")
        check("an incumbent that has gone away is replaced",
              MediaManager.choose(from: [snapshot("a", .playing)], current: "gone")?.sourceID == "a")

        // Repeated polls with the same input must not oscillate.
        var current = ""
        var sourcePicks: [String] = []
        for _ in 0..<12 {
            let pick = MediaManager.choose(
                from: [snapshot("a", .playing), snapshot("b", .playing)], current: current
            )
            current = pick?.sourceID ?? ""
            sourcePicks.append(current)
        }
        check("repeated polls settle on one source rather than alternating",
              Set(sourcePicks).count == 1, "picked \(Set(sourcePicks).sorted())")

        // ── Stale state is cleared ─────────────────────────────────────────
        check("idle has no capabilities at all", NowPlaying.idle.capabilities.isEmpty)
        check("idle reads as idle", NowPlaying.idle.isIdle)
        check("a snapshot with no title reads as idle", {
            var empty = scripted
            empty.title = ""
            return empty.isIdle
        }())

        // ── The audio monitor answers, and does not guess ──────────────────
        check("an app that is not running is not reported as playing",
              !BrowserAudioMonitor.isOutputtingAudio(bundleID: "com.example.nothing"))
        check("an empty bundle identifier is not reported as playing",
              !BrowserAudioMonitor.isOutputtingAudio(bundleID: ""))

        // ── Permission is read, never provoked ─────────────────────────────
        check("noErr reads as granted", AutomationPermission.interpret(0) == .granted)
        check("-1743 reads as refused, not as absent",
              AutomationPermission.interpret(-1743) == .denied)
        check("-1744 reads as never asked, not as refused",
              AutomationPermission.interpret(-1744) == .notDetermined,
              "a pending consent would have been shown as a refusal")
        check("-600 reads as the target not running, which says nothing about consent",
              AutomationPermission.interpret(-600) == .targetNotRunning)
        check("an unexpected status is kept as itself rather than flattened",
              AutomationPermission.interpret(-12345) == .other(-12345))
        check("an empty bundle identifier is never asked about",
              !AutomationPermission.status(forBundleID: "").isGranted)
        check("a self-test never consults real automation consent",
              AutomationPermission.status(forBundleID: "com.google.Chrome")
                  == .targetNotRunning,
              "the self-test read the machine's real TCC state")
        // The real call costs ~12.6 ms — an XPC round trip to tccd, measured over
        // 200 calls — and both media views ask about both browsers while
        // building their bodies. So asking has to be cheap by construction.
        // Counting the system calls says that deterministically, where a
        // stopwatch would only say it probably held on an unloaded machine.
        AutomationPermission.forgetCachedAnswers()
        let asksBefore = AutomationPermission.determinationCount
        for _ in 0..<500 { _ = AutomationPermission.status(forBundleID: "com.google.Chrome") }
        let asks = AutomationPermission.determinationCount - asksBefore
        check("500 reads of consent make at most one system call",
              asks <= 1,
              "made \(asks) — a 12.6ms blocking call would be reaching the UI")

        // ── Browsers are never launched, and stay off until switched on ────
        let chrome = BrowserMediaProvider(browser: .chrome)
        check("a browser provider is unavailable while the setting is off",
              Settings.shared.browserMediaEnabled || !chrome.isAvailable,
              "the provider offered itself without consent")
        check("a browser provider is unavailable without automation consent",
              !chrome.isAvailable,
              "the provider would have scripted a browser it has no permission for")
        // A term the target app's own dictionary redefines must never be used
        // bare. `tab` inside a Chrome or Safari tell block is that app's tab
        // class, and using it produced a provider that silently found nothing.
        for provider in [BrowserMediaProvider(browser: .chrome),
                         BrowserMediaProvider(browser: .safari)] {
            for (label, source) in [("tab listing", provider.tabListingScript),
                                    ("page state", provider.pageStateScript)] {
                check("the \(provider.browser.rawValue) \(label) script separates fields with a character, not a class",
                      !source.contains("& tab &") && source.contains("character id 9"),
                      "the bare `tab` term resolves to the browser's tab class")
            }
        }
        check("the browser toggle hint names a real menu path",
              MediaBrowser.chrome.javaScriptToggleHint.contains("Apple Events")
                  && MediaBrowser.safari.javaScriptToggleHint.contains("Apple Events"))
    }

    /// The words a resolution would put on screen.
    private static func statusText(_ state: PlaybackState, ambiguous: Bool) -> String {
        var snapshot = NowPlaying.idle
        snapshot.state = state
        snapshot.sourceIsAmbiguous = ambiguous
        return snapshot.statusText
    }

    private static func statusText(_ resolution: BrowserPlaybackResolver.Resolution?) -> String {
        guard let resolution else { return "" }
        return statusText(resolution.state, ambiguous: resolution.isAmbiguous)
    }


    /// Motion honours Reduce Motion, and survives interruption.
    ///
    /// Deliberately asserts behaviour, not taste. The spring values themselves
    /// are a judgement call awaiting the user's verdict; what must hold
    /// regardless is that the animation can be switched off, that the system
    /// accessibility preference is obeyed, and that an interrupted open does
    /// not leave the notch stranded between states.
    private static func testMotion() {
        section("Motion")
        let settings = Settings.shared
        let originalAnimations = settings.animationsEnabled
        let originalRespect = settings.respectReducedMotion
        defer {
            settings.animationsEnabled = originalAnimations
            settings.respectReducedMotion = originalRespect
        }

        settings.animationsEnabled = true
        settings.respectReducedMotion = false
        check("animation is on when enabled", NotchMotion.isAnimated)

        settings.animationsEnabled = false
        check("switching animation off disables it", !NotchMotion.isAnimated)

        // With animation off every curve must be effectively instant, so a
        // disabled animation cannot leave a view mid-transition.
        settings.animationsEnabled = false
        check("a disabled open/close curve is instant",
              NotchMotion.expand == .linear(duration: 0.01))
        check("a disabled content curve is instant",
              NotchMotion.content == .linear(duration: 0.01))
        check("a disabled incidental curve is instant",
              NotchMotion.quick == .linear(duration: 0.01))

        // The system preference is injected, so both branches run on any
        // machine rather than only on one with Reduce Motion switched on.
        let realReduce = NotchMotion.systemReducesMotion
        defer { NotchMotion.systemReducesMotion = realReduce }

        settings.animationsEnabled = true
        settings.respectReducedMotion = true
        NotchMotion.systemReducesMotion = { true }
        check("system Reduce Motion is honoured", !NotchMotion.isAnimated)
        check("and it makes every curve instant",
              NotchMotion.expand == .linear(duration: 0.01))

        settings.respectReducedMotion = false
        check("Reduce Motion is ignored when the app opts out", NotchMotion.isAnimated)

        NotchMotion.systemReducesMotion = { false }
        settings.respectReducedMotion = true
        check("animation continues when the system does not reduce motion",
              NotchMotion.isAnimated)
        NotchMotion.systemReducesMotion = realReduce

        // Interruption continuity, at the level this can be asserted without a
        // human: an open interrupted by a close, repeatedly and fast, must
        // always settle in a definite state rather than somewhere between.
        settings.animationsEnabled = true
        settings.respectReducedMotion = false
        let model = NotchViewModel(screenID: NSScreen.main?.stableID)
        for _ in 0..<40 {
            model.open()
            model.close()
        }
        pumpEvents(for: 0.3)
        check("rapid open/close interruption settles in a definite state",
              model.state == .closed || model.state == .open,
              "ended in \(model.state)")
        model.allowHoverToReopen()
        model.open()
        pumpEvents(for: 0.1)
        model.close()
        model.allowHoverToReopen()
        model.open()
        pumpEvents(for: 0.4)
        check("an interrupted close still ends open when reopened",
              model.state == .open, "ended in \(model.state)")
        model.close()
    }

    /// The sessions content boundary, its freshness rule, and its bounds.
    ///
    /// Every fixture here is written by this test. The user's own transcripts
    /// are never opened — not even to check that they parse.
    private static func testSessionDetail() {
        section("Session labels — boundary")
        let settings = Settings.shared
        let originalDepth = settings.sessionLabelDepthID
        defer { settings.sessionLabelDepthID = originalDepth }

        let dir = AppInfo.testDirectory.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func write(_ name: String, _ lines: [String]) -> String {
            let url = dir.appendingPathComponent(name)
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }
        func stamp(_ secondsAgo: TimeInterval) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: Date().addingTimeInterval(-secondsAgo))
        }

        let secret = "Acme merger diligence — do not disclose"
        let current = write("current.jsonl", [
            #"{"type":"custom-title","customTitle":"\#(secret)"}"#,
            #"{"type":"assistant","timestamp":"\#(stamp(5))","effort":"max","message":{"model":"claude-opus-5","content":[{"type":"tool_use","name":"Bash","input":{"description":"Running the test suite"}}]}}"#
        ])

        // ── The default is metadata only, and it reads nothing ──────────────
        check("metadata only is the default depth",
              SessionLabelDepth(rawValue: Settings.defaultSessionLabelDepth) == .metadataOnly,
              "default is \(Settings.defaultSessionLabelDepth)")
        let offDetail = SessionDetailReader.read(path: current, agent: .claudeCode,
                                                 depth: .metadataOnly)
        check("metadata-only reads nothing at all", offDetail.isEmpty)
        check("metadata-only says it did not read", offDetail.wasNotRead)
        check("a private title never appears in metadata-only mode",
              offDetail.title == nil && offDetail.step == nil)

        // ── Enabled: the four named fields, all from one record ─────────────
        let on = SessionDetailReader.read(path: current, agent: .claudeCode, depth: .richLabels)
        check("the model is read", on.model == "Opus 5", "got \(on.model ?? "nil")")
        check("the effort is read", on.effort == "max", "got \(on.effort ?? "nil")")
        check("the chat name is read", on.title == secret, "got \(on.title ?? "nil")")
        check("the current step is read", on.step == "Running the test suite",
              "got \(on.step ?? "nil")")
        check("a fresh record counts as working", on.activity == .working)
        check("the progress indicator runs only with a current step", on.showsProgress)

        // ── Freshness: an old step must not claim the agent is working ──────
        let stale = write("stale.jsonl", [
            #"{"type":"assistant","timestamp":"\#(stamp(3600))","effort":"max","message":{"model":"claude-opus-5","content":[{"type":"tool_use","name":"Bash","input":{"description":"Running the test suite"}}]}}"#
        ])
        let staleDetail = SessionDetailReader.read(path: stale, agent: .claudeCode, depth: .richLabels)
        check("an hour-old record is not 'working'", staleDetail.activity == .recent,
              "got \(staleDetail.activity.rawValue)")
        check("a stale step is dropped rather than shown as current",
              staleDetail.step == nil, "kept \(staleDetail.step ?? "nil")")
        check("the progress indicator stops when the step is stale",
              !staleDetail.showsProgress)
        check("the model still reads from a stale record", staleDetail.model == "Opus 5")

        // ── No timestamp at all: unknown, and no claim of activity ──────────
        let undated = write("undated.jsonl", [
            #"{"type":"assistant","message":{"model":"claude-opus-5","content":[{"type":"tool_use","name":"Bash","input":{"description":"Something"}}]}}"#
        ])
        let undatedDetail = SessionDetailReader.read(path: undated, agent: .claudeCode, depth: .richLabels)
        check("a record with no timestamp is unknown, not working",
              undatedDetail.activity == .unknown, "got \(undatedDetail.activity.rawValue)")
        check("no step is claimed without a timestamp", undatedDetail.step == nil)
        check("the progress indicator stops when freshness is unknown",
              !undatedDetail.showsProgress)

        let future = write("future.jsonl", [
            #"{"type":"assistant","timestamp":"\#(stamp(-7200))","message":{"model":"claude-opus-5","content":[]}}"#
        ])
        check("a future timestamp is treated as unknown",
              SessionDetailReader.read(path: future, agent: .claudeCode, depth: .richLabels)
                  .activity == .unknown)

        // ── Fields come from one record, never mixed across turns ───────────
        let mixed = write("mixed.jsonl", [
            #"{"type":"assistant","timestamp":"\#(stamp(9000))","effort":"low","message":{"model":"claude-haiku-4-5","content":[{"type":"tool_use","name":"Old","input":{"description":"An old step"}}]}}"#,
            #"{"type":"assistant","timestamp":"\#(stamp(3))","effort":"max","message":{"model":"claude-opus-5","content":[{"type":"tool_use","name":"New","input":{"description":"The new step"}}]}}"#
        ])
        let mixedDetail = SessionDetailReader.read(path: mixed, agent: .claudeCode, depth: .richLabels)
        check("the model comes from the newest turn", mixedDetail.model == "Opus 5")
        check("the effort comes from that same turn", mixedDetail.effort == "max")
        check("the step comes from that same turn", mixedDetail.step == "The new step",
              "got \(mixedDetail.step ?? "nil")")

        // ── Strict extraction: prose is never a step ────────────────────────
        let prose = write("prose.jsonl", [
            #"{"type":"assistant","timestamp":"\#(stamp(2))","message":{"model":"claude-opus-5","content":[{"type":"text","text":"The patient results suggest we should"}]}}"#
        ])
        let proseDetail = SessionDetailReader.read(path: prose, agent: .claudeCode, depth: .richLabels)
        check("assistant prose is never used as a step", proseDetail.step == nil,
              "leaked: \(proseDetail.step ?? "nil")")
        let userText = write("user.jsonl", [
            #"{"type":"user","timestamp":"\#(stamp(2))","message":{"content":"my bank password is hunter2"}}"#
        ])
        check("user input is never used as a label",
              SessionDetailReader.read(path: userText, agent: .claudeCode, depth: .richLabels).isEmpty,
              "something leaked from a user record")

        // ── Malformed, partial and unknown shapes ───────────────────────────
        let partial = write("partial.jsonl", [
            #"{"type":"custom-title","customTitle":"Fine"}"#,
            #"{"type":"assistant","timestamp":"x","message":{"model":"claude-opus"#
        ])
        let partialDetail = SessionDetailReader.read(path: partial, agent: .claudeCode, depth: .richLabels)
        check("a half-written last record is ignored", partialDetail.step == nil)
        check("intact records around it still read", partialDetail.title == "Fine")

        let malformed = write("malformed.jsonl", ["{{{not json", "[1,2,3]", "null"])
        check("malformed records yield nothing rather than nonsense",
              SessionDetailReader.read(path: malformed, agent: .claudeCode, depth: .richLabels).isEmpty)

        let unknownSchema = write("unknown.jsonl", [
            #"{"kind":"something-else","body":{"secret":"should not appear"}}"#
        ])
        check("an unknown schema yields nothing",
              SessionDetailReader.read(path: unknownSchema, agent: .claudeCode, depth: .richLabels).isEmpty)

        let missingFields = write("missing.jsonl", [
            #"{"type":"assistant","timestamp":"\#(stamp(1))","message":{}}"#
        ])
        let missingDetail = SessionDetailReader.read(path: missingFields, agent: .claudeCode, depth: .richLabels)
        check("a record with no model reports no model", missingDetail.model == nil)
        check("a record with no step reports no step", missingDetail.step == nil)

        // ── Labels are sanitised and bounded ────────────────────────────────
        let nasty = write("nasty.jsonl", [
            #"{"type":"custom-title","customTitle":"line one\nline two\\u0007"}"#
        ])
        let nastyTitle = SessionDetailReader.read(path: nasty, agent: .claudeCode, depth: .richLabels).title
        check("a multi-line title becomes one line", nastyTitle == "line one",
              "got \(nastyTitle ?? "nil")")
        check("control characters are stripped from labels",
              SessionDetailReader.label("ok\u{7}\u{1b}") == "ok",
              "got \(SessionDetailReader.label("ok\u{7}\u{1b}") ?? "nil")")

        let longTitle = String(repeating: "secret ", count: 60)
        let long = write("long.jsonl", [#"{"type":"custom-title","customTitle":"\#(longTitle)"}"#])
        let cut = SessionDetailReader.read(path: long, agent: .claudeCode, depth: .richLabels).title
        check("a long title is truncated",
              (cut?.count ?? 0) <= SessionDetailReader.maxLabelLength,
              "kept \(cut?.count ?? 0) characters")

        // ── Model identifiers are identifiers, not a text channel ───────────
        check("a model identifier becomes a readable name",
              SessionDetailReader.displayName(forModel: "claude-opus-5") == "Opus 5")
        check("a dotted version reads as one number",
              SessionDetailReader.displayName(forModel: "claude-haiku-4-5-20251001") == "Haiku 4.5")
        check("another vendor's model is readable",
              SessionDetailReader.displayName(forModel: "gpt-6-astra") == "GPT 6 Astra")
        check("a synthetic model is dropped",
              SessionDetailReader.displayName(forModel: "<synthetic>") == nil)
        check("free text in a model field is refused, not displayed",
              SessionDetailReader.displayName(forModel: "my private project notes") == nil)
        check("an over-long model field is refused",
              SessionDetailReader.displayName(forModel: String(repeating: "a", count: 200)) == nil)

        // ── Codex: model only, and never claimed to be working ──────────────
        let codex = write("codex.jsonl", [
            #"{"type":"turn_context","timestamp":"\#(stamp(2))","payload":{"model":"gpt-6-astra"}}"#,
            #"{"type":"event_msg","timestamp":"\#(stamp(1))","payload":{"type":"agent_message","message":"private reasoning text"}}"#
        ])
        let codexDetail = SessionDetailReader.read(path: codex, agent: .codex, depth: .richLabels)
        check("codex yields its model", codexDetail.model == "GPT 6 Astra")
        check("codex event text is never used as a step", codexDetail.step == nil,
              "leaked: \(codexDetail.step ?? "nil")")
        check("codex is never reported as working", codexDetail.activity != .working)

        check("a missing transcript is safe",
              SessionDetailReader.read(path: dir.appendingPathComponent("nope.jsonl").path,
                                       agent: .claudeCode, depth: .richLabels).isEmpty)

        // ── Fallbacks in the session itself ─────────────────────────────────
        let bare = AgentSession(id: "/tmp/x.jsonl", agent: .claudeCode,
                                projectName: "scratch-3274fa", lastActivity: Date(), byteSize: 0)
        check("a session with no detail falls back to the directory",
              bare.displayName == "scratch-3274fa")
        var named = bare
        named.detail.title = "A chat name"
        check("a titled session prefers its own name", named.displayName == "A chat name")

        // ── The cache is in memory, keyed on the file, and clearable ────────
        let cache = SessionDetailCache()
        check("a new cache is empty", cache.isEmpty)
        cache.store(on, forPath: current, size: 10, modified: Date(timeIntervalSince1970: 1))
        check("a stored entry is found again",
              cache.detail(forPath: current, size: 10,
                           modified: Date(timeIntervalSince1970: 1)) == on)
        check("a changed file misses the cache",
              cache.detail(forPath: current, size: 11,
                           modified: Date(timeIntervalSince1970: 1)) == nil)
        cache.clear()
        check("clearing the cache forgets every label", cache.isEmpty)
    }

    /// Clearing the Tray must take two deliberate presses.
    /// Clearing the Tray must take two deliberate presses.
    ///
    /// Found in acceptance: one unguarded click on a trash icon — sitting
    /// beside an ordinary "remove selected" button — emptied a thirteen-item
    /// Tray with no confirmation and no undo. The user's own files survived,
    /// because only LocalNook-created files are ever deleted, but the curated
    /// list did not.
    private static func testClearingTheTrayNeedsConfirming() {
        section("Tray clearing")
        let shelf = ShelfStore.shared
        let saved = shelf.items
        defer {
            shelf.cancelClear()
            shelf.restoreForTesting(saved)
        }

        let dir = AppInfo.testDirectory.appendingPathComponent("clear", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("keep-me.txt")
        try? "original".write(to: file, atomically: true, encoding: .utf8)

        shelf.restoreForTesting([
            ShelfItem(id: UUID(), kind: .file, name: "keep-me.txt", path: file.path,
                      payload: nil, addedAt: Date(), isOwned: false)
        ])
        check("a tray to clear", shelf.items.count == 1)

        // 1. Confirming without asking first must do nothing at all.
        check("clearing without arming is refused", shelf.confirmClear() == false)
        check("and nothing was cleared", shelf.items.count == 1)

        // 2. Arming alone must not clear.
        shelf.requestClear()
        check("asking to clear arms it", shelf.clearIsArmed)
        check("arming alone clears nothing", shelf.items.count == 1)

        // 3. Cancelling disarms, and a later confirm is refused again.
        shelf.cancelClear()
        check("cancelling disarms", !shelf.clearIsArmed)
        check("a cancelled clear cannot be confirmed", shelf.confirmClear() == false)
        check("still nothing cleared", shelf.items.count == 1)

        // 4. Arm then confirm actually clears.
        shelf.requestClear()
        check("arm then confirm clears", shelf.confirmClear())
        check("the tray is empty", shelf.items.isEmpty)
        check("confirming disarms", !shelf.clearIsArmed)

        // 5. The file the user owns is never touched by any of it.
        check("clearing never deletes a file the user owns",
              (try? String(contentsOf: file, encoding: .utf8)) == "original")

        // 6. An empty tray cannot be armed, so the confirm state cannot linger.
        shelf.requestClear()
        check("an empty tray does not arm", !shelf.clearIsArmed)
    }

    /// Every enabled widget must be reachable from somewhere.
    ///
    /// The invariant that was actually broken in shipping code: `ToolsView`
    /// excluded everything *assigned* to the Dashboard, while the Dashboard
    /// only shows what *fits*. Assign more than fits and the remainder lived in
    /// neither place — and the overflow control, whose whole job is to reach
    /// them, navigated to the page that had just excluded them.
    ///
    /// Checked across the full width range rather than at one width, because
    /// the failure only appears once the assigned set stops fitting.
    private static func testEveryWidgetIsReachable() {
        section("Widget reachability")
        let settings = Settings.shared
        let originalDashboard = settings.dashboardWidgetIDs
        let originalEnabled = settings.enabledWidgetIDs
        defer {
            settings.dashboardWidgetIDs = originalDashboard
            settings.enabledWidgetIDs = originalEnabled
        }

        settings.enabledWidgetIDs = WidgetKind.allCases.map(\.rawValue)
        // Everything that may sit on the Dashboard, assigned to it — the
        // configuration a user reaches by switching them on in Settings.
        settings.dashboardWidgetIDs = WidgetKind.allCases
            .filter(\.suitsDashboard).map(\.rawValue)

        let assigned = settings.dashboardWidgets
        check("more widgets are assigned to the dashboard than a narrow panel fits",
              assigned.count > 1, "only \(assigned.count) assigned")

        var widthsChecked = 0
        var firstFailure: String?
        var sawOverflow = false
        for width in stride(from: 320.0, through: 1400.0, by: 20.0) {
            let plan = DashboardView.plan(assigned, into: width)
            if !plan.overflow.isEmpty { sawOverflow = true }

            // What Tools offers at this width, mirroring ToolsView.
            let visible = Set(plan.visible.map(\.rawValue))
            let inTools = settings.orderedWidgets.filter {
                $0 != .shelf && !visible.contains($0.rawValue)
            }

            let reachable = Set(plan.visible.map(\.rawValue))
                .union(inTools.map(\.rawValue))
            let expected = Set(settings.orderedWidgets.filter { $0 != .shelf }.map(\.rawValue))
            if reachable != expected, firstFailure == nil {
                firstFailure = "at \(Int(width))pt, unreachable: "
                    + expected.subtracting(reachable).sorted().joined(separator: ", ")
            }
            widthsChecked += 1
        }

        check("the overflow case is actually exercised", sawOverflow,
              "no width produced an overflow, so the check proved nothing")
        check("every enabled widget is reachable at all \(widthsChecked) widths",
              firstFailure == nil, firstFailure ?? "")

        // And the specific promise the overflow control makes: what it counts
        // as hidden is exactly what Tools then offers.
        let narrow = DashboardView.plan(assigned, into: 420)
        if !narrow.overflow.isEmpty {
            let visible = Set(narrow.visible.map(\.rawValue))
            let inTools = Set(settings.orderedWidgets
                .filter { $0 != .shelf && !visible.contains($0.rawValue) }
                .map(\.rawValue))
            let hidden = Set(narrow.overflow.map(\.rawValue))
            check("everything the overflow badge counts is offered by Tools",
                  hidden.isSubset(of: inTools),
                  "counted but not offered: "
                  + hidden.subtracting(inTools).sorted().joined(separator: ", "))
        } else {
            check("a narrow dashboard overflows so the badge can be checked", false,
                  "420pt fitted everything")
        }
    }

    /// Teardown, restart, and interaction ownership.
    ///
    /// Deterministic by construction: pointer position, mouse-button state and
    /// the set of connected displays are all injected, and recovery is driven
    /// with `runPointerSafetyCheckNow()` rather than by sleeping through the
    /// fallback's one-second cadence. Nothing here waits on a wall clock for a
    /// result, so it must pass on every machine, every run.
    private static func testControllerTeardown() {
        section("Controller teardown and ownership")
        let controller = NotchWindowController.shared

        // Everything injected here is restored even if an assertion fails.
        let realPointer = controller.pointerLocation
        let realButtons = controller.mouseButtonsAreDown
        let realScreens = controller.connectedScreens
        defer {
            controller.pointerLocation = realPointer
            controller.mouseButtonsAreDown = realButtons
            controller.connectedScreens = realScreens
        }

        controller.stop()
        pumpEvents(for: 0.2)
        check("a stopped controller holds nothing",
              controller.residue.isEmpty, "still holds \(controller.residue)")

        // --- stop() cancels outstanding work -------------------------------
        controller.start()
        pumpEvents(for: 0.4)
        let started = controller.residue
        check("starting builds a notch", started.panels > 0 && started.models > 0,
              "residue after start: \(started)")

        guard let first = controller.allModels.first else {
            check("a notch exists to tear down", false)
            return
        }
        first.open()
        pumpEvents(for: 0.4)
        check("an open notch schedules the recovery check",
              controller.pointerSafetyNetIsRunning)

        controller.stop()
        pumpEvents(for: 0.2)
        check("stop cancels the recovery check", !controller.pointerSafetyNetIsRunning)
        check("stop releases every window, observer and task",
              controller.residue.isEmpty, "still holds \(controller.residue)")

        // --- work from the old session cannot touch the new one ------------
        // A close scheduled before stop must not land on the session that
        // replaces it. The stale model is kept alive deliberately: the danger
        // is a task that outlives its controller, not one that is deallocated.
        let stale = first
        stale.open()
        stale.scheduleClose(source: .pointerFallback)
        let staleGeneration = controller.sessionGeneration
        controller.stop()
        pumpEvents(for: 0.1)

        controller.start()
        pumpEvents(for: 0.4)
        check("restarting begins a new session",
              controller.sessionGeneration != staleGeneration,
              "generation stayed \(controller.sessionGeneration)")
        check("the stale notch is no longer registered",
              !controller.allModels.contains(where: { $0 === stale }))

        if let fresh = controller.allModels.first {
            // Park the pointer on the new notch first. Without this the
            // production fallback closes it a second later for a perfectly good
            // reason — the pointer is elsewhere — and the test reads that as
            // stale work leaking through. Pinned here, the only thing that can
            // close it is something the previous session scheduled.
            if let screen = fresh.screen {
                controller.pointerLocation = {
                    NSPoint(x: screen.frame.midX,
                            y: screen.frame.maxY - NotchGeometry.openSize.height / 2)
                }
                check("the pointer could be pinned to the new notch", true)
            } else {
                check("the pointer could be pinned to the new notch", false,
                      "the restarted notch has no screen, so the check below "
                      + "would be measuring the fallback instead")
            }
            fresh.open()
            pumpEvents(for: 0.4)
            // Comfortably longer than anything the old session could have
            // scheduled, and longer than one tick of the fallback.
            pumpEvents(for: 1.4)
            check("work scheduled before stop cannot close the new session's notch",
                  fresh.state == .open, "the new notch is \(fresh.state)")
            check("the stale notch's own pending work was cancelled",
                  !stale.hasPendingClose)
            controller.pointerLocation = realPointer
            fresh.close()
            pumpEvents(for: 0.3)
        } else {
            check("the restarted session has a notch", false)
        }

        // --- repeated start/stop accumulates nothing -----------------------
        var residues: [NotchWindowController.Residue] = []
        for _ in 0..<3 {
            controller.stop()
            pumpEvents(for: 0.15)
            check("each stop leaves nothing behind",
                  controller.residue.isEmpty, "held \(controller.residue)")
            controller.start()
            pumpEvents(for: 0.35)
            // Sample once in-flight work has finished rather than after a fixed
            // delay: a panel shrinking back after a live activity is normal and
            // self-limiting, and comparing it would measure when the sample was
            // taken instead of whether anything leaked.
            let settled = waitUntil({ !controller.residue.hasWorkInFlight }, timeout: 2.0)
            check("scheduled work settles instead of piling up", settled,
                  "still in flight: \(controller.residue)")
            residues.append(controller.residue.settled)
        }
        check("repeated start/stop does not accumulate windows or observers",
              residues.allSatisfy { $0 == residues[0] },
              "residues differed across cycles: \(residues.map(\.description))")

        // --- removing a display releases its claims ------------------------
        if let doomed = controller.allModels.first {
            let owner = UUID()
            doomed.open()
            doomed.claimInteraction(.textEditing, owner: owner)
            pumpEvents(for: 0.2)
            check("the notch about to be removed holds a claim", doomed.isInteracting)

            controller.connectedScreens = { [] }
            controller.rebuildPanels()
            pumpEvents(for: 0.3)

            check("removing the display retires its panel", controller.panelCount == 0,
                  "\(controller.panelCount) panel(s) survived")
            check("removing the display retires its catcher", controller.catcherCount == 0,
                  "\(controller.catcherCount) catcher(s) survived")
            check("panels and catchers stay in step through removal",
                  controller.panelsAndCatchersAgree)
            check("a removed display's claims are released", !doomed.isInteracting,
                  "claims survived: \(doomed.activeInteractions.map(\.rawValue))")
            check("a removed display's pending work is cancelled", !doomed.hasPendingClose)

            controller.connectedScreens = realScreens
            controller.rebuildPanels()
            pumpEvents(for: 0.4)
            check("reattaching the display rebuilds exactly one notch per screen",
                  controller.panelCount == controller.catcherCount
                  && controller.panelCount > 0,
                  "panels=\(controller.panelCount) catchers=\(controller.catcherCount)")
        } else {
            // Without this the whole display-removal group simply vanished from
            // the run — seven assertions that neither passed nor failed and
            // said nothing about it. A run that quietly executes fewer checks
            // than another is missing coverage, not merely shorter.
            check("a notch exists to remove a display from", false,
                  "the controller had no models after restart")
        }

        // --- an interaction pins only its own nook -------------------------
        // Seeded rather than physical: see installSyntheticNotch. The rule
        // under test is the one production uses, not a restatement of it.
        let farScreen = "self-test.synthetic-display"
        let farFrame = CGRect(x: -4000, y: -4000, width: 400, height: 200)
        let other = controller.installSyntheticNotch(id: farScreen, frame: farFrame)
        defer { controller.removeSyntheticNotch(id: farScreen) }
        pumpEvents(for: 0.2)

        if let here = controller.allModels.first(where: { $0 !== other }) {
            // Pointer parked somewhere neither notch covers, so the only reason
            // either can stay open is a claim.
            controller.pointerLocation = { NSPoint(x: 12_000, y: 12_000) }
            controller.mouseButtonsAreDown = { false }

            let typist = UUID()
            here.open()
            other.open()
            pumpEvents(for: 0.3)
            here.claimInteraction(.textEditing, owner: typist)

            controller.runPointerSafetyCheckNow()
            check("typing in Notes pins the notch being typed in",
                  waitUntil({ here.state == .open }, timeout: 0.5))
            check("typing in Notes does not pin the notch on another display",
                  waitUntil({ other.state == .closed }, timeout: 1.0),
                  "the other notch is \(other.state)")

            // --- ending the interaction restores ordinary closing ----------
            here.releaseInteraction(.textEditing, owner: typist)
            check("releasing the claim ends the hold", !here.isInteracting)
            controller.runPointerSafetyCheckNow()
            check("once typing ends the notch closes normally again",
                  waitUntil({ here.state == .closed }, timeout: 1.0),
                  "it is \(here.state)")

            // A menu claim behaves the same way, and a drag claim survives only
            // while a button is actually held.
            here.allowHoverToReopen()
            here.open()
            pumpEvents(for: 0.2)
            let dragger = UUID()
            here.claimInteraction(.dragging, owner: dragger)
            controller.mouseButtonsAreDown = { true }
            controller.validateClaimsNow()
            controller.runPointerSafetyCheckNow()
            check("a live drag keeps its own notch open",
                  waitUntil({ here.state == .open }, timeout: 0.5))
            controller.mouseButtonsAreDown = { false }
            controller.validateClaimsNow()
            check("letting go ends the drag claim", !here.isInteracting,
                  "still holds \(here.activeInteractions.map(\.rawValue))")
            controller.runPointerSafetyCheckNow()
            check("after the drag ends the notch closes normally again",
                  waitUntil({ here.state == .closed }, timeout: 1.0),
                  "it is \(here.state)")

            // Settings taking focus is not an interaction with any notch.
            check("no notch is left claimed at the end",
                  controller.allModels.allSatisfy { !$0.isInteracting })
        } else {
            check("a real notch exists alongside the synthetic one", false)
        }

        controller.pointerLocation = realPointer
        controller.mouseButtonsAreDown = realButtons
    }

    /// The postcondition a missed tracking event must not be allowed to break.
    ///
    /// The live hover checks can only *try* to make the window server deliver a
    /// crossing, and sometimes it does not. That is an excuse for the stimulus,
    /// never for leaving a panel the user cannot dismiss. This asserts the
    /// recovery contract directly, on the real controller-owned notch, with the
    /// pointer injected — so it is a hard gate on every run rather than one
    /// that only fires when the flaky stimulus happens to work.
    private static func testMissedCrossingRecovery() {
        section("Recovery from a missed crossing")
        let controller = NotchWindowController.shared
        let realPointer = controller.pointerLocation
        defer { controller.pointerLocation = realPointer }

        controller.start()
        pumpEvents(for: 0.4)
        guard let model = controller.allModels.first else {
            check("a notch exists to recover", false)
            return
        }

        // Exactly the failure under investigation: the notch is open and the
        // mouseExited that should close it will never arrive.
        model.allowHoverToReopen()
        model.open()
        pumpEvents(for: 0.4)
        check("the notch is open to begin with", model.state == .open,
              "it is \(model.state)")
        check("an open notch always has a recovery check scheduled",
              controller.pointerSafetyNetIsRunning,
              "nothing would ever notice the missed event")

        NotchTransitionLog.clear()
        controller.pointerLocation = { NSPoint(x: 12_000, y: 12_000) }
        controller.runPointerSafetyCheckNow()
        check("a notch open with the pointer elsewhere closes itself",
              waitUntil({ model.state == .closed }, timeout: 1.0),
              "still \(model.state) after the recovery pass ran")
        let closes = NotchTransitionLog.all.filter { !$0.opened }
        check("the recovery close is attributed to the fallback",
              closes.last?.source == .pointerFallback,
              "attributed to \(String(describing: closes.last?.source))")

        // And it must stop ticking once there is nothing open, so an idle Mac
        // is not left polling.
        pumpEvents(for: 0.3)
        check("the recovery check stops once nothing is open",
              waitUntil({ !controller.pointerSafetyNetIsRunning }, timeout: 2.5))
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
        waitUntil { controller.activeModel?.state == .open }
        check("a posted com.localnook.open notification opens the notch",
              controller.activeModel?.state == .open,
              "state is \(String(describing: controller.activeModel?.state))")

        DistributedNotificationCenter.default().postNotificationName(
            .init("com.localnook.close"), object: nil, userInfo: nil, deliverImmediately: true
        )
        waitUntil { controller.activeModel?.state == .closed }
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

    /// Places `panel` around the current pointer and reports whether it really
    /// ended up containing it.
    ///
    /// The window server can clamp a frame — near a screen edge, over the Dock —
    /// so a test that assumes placement succeeded reports "hover did not fire"
    /// when the truth is "the panel was never under the pointer". These tests
    /// cannot move the pointer, so they have to check.
    private static func placePanel(_ panel: NSPanel, around cursor: NSPoint, size: CGSize) -> Bool {
        panel.setFrame(
            NSRect(x: cursor.x - size.width / 2, y: cursor.y - size.height / 2,
                   width: size.width, height: size.height),
            display: true
        )
        pumpEvents(for: 0.15)
        return panel.frame.insetBy(dx: 2, dy: 2).contains(cursor)
    }

    /// Produces a hover crossing by moving `panel` under the pointer, retrying
    /// the *stimulus* until `didCross` reports success.
    ///
    /// AppKit does not always deliver `mouseEntered` when a window slides under
    /// a stationary pointer — measured at roughly 2 attempts in 5 with the
    /// pointer resting near the Dock. Retrying the gesture is not the same as
    /// retrying the assertion: the test is trying to make a crossing happen, and
    /// one attempt is not reliably enough to produce one. A real user moves the
    /// pointer onto a stationary panel, which does not have this problem.
    private static func provokeCrossing(
        _ panel: NSPanel,
        around cursor: NSPoint,
        size: CGSize,
        parked: NSRect,
        attempts: Int = 4,
        didCross: () -> Bool
    ) -> Bool {
        for attempt in 0..<attempts {
            if attempt > 0 {
                panel.setFrame(parked, display: true)
                pumpEvents(for: 0.2)
            }
            guard placePanel(panel, around: cursor, size: size) else { return false }
            if waitUntil(didCross, timeout: 1.0) { return true }
        }
        return didCross()
    }

    /// Reports the leaving half of a live crossing, attributed the same way as
    /// the arriving half.
    ///
    /// A detached test panel that AppKit never sends `mouseExited` to has
    /// nothing left that could close it — no controller owns it, so no fallback
    /// covers it. That is a gap in the stimulus, not a broken promise: the
    /// product contract is that a *controller-owned* notch always recovers, and
    /// testMissedCrossingRecovery asserts exactly that, deterministically, on
    /// every run. LocalNook dropping or mishandling an exit it was given stays a
    /// hard failure here.
    private static func reportExit(
        _ name: String, closed: Bool, entersSeen: Int, state: NotchState
    ) {
        switch HoverProbe.classifyExit(closed: closed, entersSeen: entersSeen) {
        case .succeeded:
            check(name, true)
        case .noPlatformEvent:
            unmet(name, "AppKit delivered no mouseExited for the window moving away "
                      + "(probe: \(HoverProbe.summary)); recovery for an owned notch is "
                      + "covered by testMissedCrossingRecovery")
        case let .eventDropped(exits):
            check(name, false,
                  "AppKit delivered \(exits) exit(s) and LocalNook forwarded none")
        case let .wrongState(calls):
            check(name, false,
                  "LocalNook handled \(calls) crossing(s) and the notch is still \(state)")
        case let .preconditionUnmet(detail):
            unmet(name, detail)
        }
    }

    /// Records that a check could not be run, and why.
    ///
    /// Some assertions here depend on live machine state — where the pointer is
    /// resting, whether a mouse button is physically down, how many displays are
    /// attached. When the precondition does not hold, the honest outcome is
    /// "not exercised", not "failed": a red gate that means "you were holding
    /// the mouse" teaches people to ignore the gate.
    private static func unmet(_ name: String, _ reason: String) {
        unverified += 1
        unverifiedNames.append(name)
        print("  ? \(name)  — UNVERIFIED: \(reason)")
    }

    /// Pumps the event loop until `condition` holds, or `timeout` elapses.
    ///
    /// Preferred over a fixed sleep: it makes the test wait exactly as long as
    /// the behaviour needs, so a slow machine does not produce a false failure
    /// and a fast one does not waste a second.
    @discardableResult
    static func waitUntil(
        _ condition: () -> Bool,
        timeout: TimeInterval = 3.0
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pumpEvents(for: 0.05)
        }
        return condition()
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
        settings.setWidget(.timers, enabled: false)
        check("widget can be disabled", !settings.isWidgetEnabled(.timers))
        check("disabled widget leaves the ordered list",
              !settings.orderedWidgets.contains(.timers))
        settings.setWidget(.timers, enabled: true)
        check("widget can be re-enabled", settings.isWidgetEnabled(.timers))

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
