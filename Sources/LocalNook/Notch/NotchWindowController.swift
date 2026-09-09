//
//  NotchWindowController.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Owns the panel(s), keeps them positioned across display and power events,
//  and routes global mouse movement to hover open/close.
//

import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// Commands LocalNook accepts from outside the app.
enum NotchCommand: Sendable {
    case toggle, open, close
    /// Open the notch straight onto a page.
    case show(NotchPage)
    /// Open on every display at once. Useful for scripting a multi-monitor
    /// setup, and the only way to inspect a panel on a display the pointer is
    /// not currently on.
    case openEverywhere
    /// Not scriptable — raised by the system lock/unlock notifications.
    case screenLocked, screenUnlocked
}

/// Receives `DistributedNotificationCenter` callbacks off the main actor and
/// forwards them onto it.
///
/// Exists because the notification centre invokes its selector through the
/// Objective-C runtime, which cannot call a `@MainActor`-isolated method.
nonisolated final class DistributedCommandBridge: NSObject, @unchecked Sendable {
    private let handler: @Sendable (NotchCommand) -> Void

    private static let mapping: [(name: String, command: NotchCommand)] = [
        ("com.localnook.toggle", .toggle),
        ("com.localnook.open", .open),
        ("com.localnook.close", .close),
        ("com.localnook.dashboard", .show(.dashboard)),
        ("com.localnook.tray", .show(.tray)),
        ("com.localnook.tools", .show(.tools)),
        ("com.localnook.open.all", .openEverywhere),
        ("com.apple.screenIsLocked", .screenLocked),
        ("com.apple.screenIsUnlocked", .screenUnlocked),
    ]

    init(handler: @escaping @Sendable (NotchCommand) -> Void) {
        self.handler = handler
        super.init()
    }

    func register() {
        let center = DistributedNotificationCenter.default()
        for entry in Self.mapping {
            center.addObserver(
                self,
                selector: #selector(receive(_:)),
                name: .init(entry.name),
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
        }
    }

    func unregister() {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func receive(_ note: Notification) {
        guard let command = Self.mapping.first(where: { $0.name == note.name.rawValue })?.command
        else { return }
        let handler = handler
        DispatchQueue.main.async { handler(command) }
    }
}

final class NotchWindowController: NSObject {
    static let shared = NotchWindowController()

    private var panels: [String: NotchPanel] = [:]
    /// Tiny always-interactive catchers, one per panel. See NotchHitPanel.
    private var hitPanels: [String: NotchHitPanel] = [:]
    private var models: [String: NotchViewModel] = [:]
    private var mouseMonitor: Any?
    private var clickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var stateObservers = Set<AnyCancellable>()
    private var notificationBridge: DistributedCommandBridge?
    /// Low-frequency safety net, alive only while a notch is open. See
    /// `startPointerSafetyNet()`.
    private var pointerSafetyTask: Task<Void, Never>?
    private var isScreenLocked = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var geometryTask: Task<Void, Never>?
    private var started = false
    private var shrinkTasks: [String: Task<Void, Never>] = [:]
    private var lastScreenSignature: String = ""

    /// Only used when `useElevatedSpace` is on; see ARCHITECTURE.md § Private APIs.
    private var elevatedSpace: ElevatedWindowSpace?

    private let settings = Settings.shared

    private override init() { super.init() }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        sessionGeneration &+= 1
        rebuildPanels()
        installEventMonitors()
        observeSystemEvents()
        LiveActivityCenter.shared.$current.receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncPanelExtents()
                self?.syncWingHover()
            }.store(in: &cancellables)
        LiveActivityCenter.shared.$trailingExpanded.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncPanelExtents() }.store(in: &cancellables)
        HUDController.shared.$state.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncPanelExtents() }.store(in: &cancellables)
        settings.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] in self?.rebuildPanels() }.store(in: &cancellables)
    }

    func stop() {
        started = false
        wingHoverTimer?.invalidate()
        wingHoverTimer = nil
        cancellables.removeAll()
        // Stop means stop. A recovery task left running against torn-down state
        // keeps polling after the controller is finished with, and — because it
        // still holds a reference to the models — can close a notch belonging to
        // a later session.
        pointerSafetyTask?.cancel()
        pointerSafetyTask = nil
        geometryTask?.cancel()
        geometryTask = nil
        shrinkTasks.values.forEach { $0.cancel() }
        shrinkTasks.removeAll()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        stateObservers.removeAll()
        notificationBridge?.unregister()
        notificationBridge = nil
        removeEventMonitors()
        teardownPanels()
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    /// The model for the display the pointer is currently on, else the primary.
    var activeModel: NotchViewModel? {
        let mouse = pointerLocation()
        if let match = models.first(where: { key, _ in
            NSScreen.screen(withStableID: key)?.frame.contains(mouse) ?? false
        }) {
            return match.value
        }
        return models[primaryScreenID() ?? ""] ?? models.values.first
    }

    var allModels: [NotchViewModel] { Array(models.values) }

    /// Number of live panels. Used by the self-test to catch orphaned windows
    /// after a display is attached or removed.
    var panelCount: Int { panels.count }

    /// Number of live input catchers. Must always equal `panelCount`; a
    /// mismatch means a hot-plug leaked an invisible window onto the menu bar.
    var catcherCount: Int { hitPanels.count }

    /// Catchers and panels agree on which displays exist.
    var panelsAndCatchersAgree: Bool {
        Set(panels.keys) == Set(hitPanels.keys)
    }

    /// Inspection hooks for the self-test: which window is currently live, and
    /// how much of the screen the interactive one covers.
    var inertDrawingPanels: Bool {
        models.allSatisfy { id, model in
            let expectInert = model.state == .closed
            return panels[id]?.ignoresMouseEvents == expectInert
        }
    }

    var activeCatchers: Bool {
        models.allSatisfy { id, model in
            let expectActive = model.state == .closed
            return hitPanels[id]?.ignoresMouseEvents == !expectActive
        }
    }

    /// Per-display frames, so a multi-monitor setup can be checked display by
    /// display rather than comparing whichever entry a dictionary yields first.
    var catcherFramesByScreen: [String: CGRect] {
        hitPanels.mapValues(\.frame)
    }

    var drawingPanelFramesByScreen: [String: CGRect] {
        panels.mapValues(\.frame)
    }

    var modelsByScreen: [String: NotchViewModel] { models }

    /// True when every panel is still associated with a connected display.
    var allPanelsOnLiveScreens: Bool {
        panels.keys.allSatisfy { NSScreen.screen(withStableID: $0) != nil }
    }

    // MARK: Test seams and teardown inspection

    /// Bumped by every `start()`. Work captured before a `stop()` can compare
    /// this against the value it captured and decline to touch a later session.
    private(set) var sessionGeneration = 0

    /// Displays the controller should consider hosting a notch on.
    ///
    /// Injectable so attaching and removing a display can be exercised without
    /// physically unplugging a monitor. Everything downstream — retiring panels,
    /// releasing the claims that belonged to them — runs the production path.
    var connectedScreens: () -> [NSScreen] = { NSScreen.screens }

    /// Everything `stop()` is responsible for releasing, in one place, so a
    /// leak shows up as a number rather than as a symptom three tests later.
    struct Residue: Equatable, CustomStringConvertible {
        var panels = 0
        var catchers = 0
        var models = 0
        var claims = 0
        var combineSubscriptions = 0
        var stateObservers = 0
        var notificationObservers = 0
        var eventMonitors = 0
        var shrinkTasks = 0
        var pointerSafetyNet = false
        var geometryTask = false
        var commandBridge = false

        /// A stopped controller must hold none of it.
        var isEmpty: Bool { self == Residue() }

        /// Work that is in flight rather than held.
        ///
        /// A panel shrinking back after a live activity ends is normal and
        /// finishes on its own. Comparing it between start/stop cycles measures
        /// when the sample was taken, not whether anything leaked.
        var hasWorkInFlight: Bool { shrinkTasks > 0 || pointerSafetyNet }

        /// The parts that must not grow across repeated start/stop cycles.
        var settled: Residue {
            var copy = self
            copy.shrinkTasks = 0
            copy.pointerSafetyNet = false
            return copy
        }

        var description: String {
            var parts: [String] = []
            if panels > 0 { parts.append("panels=\(panels)") }
            if catchers > 0 { parts.append("catchers=\(catchers)") }
            if models > 0 { parts.append("models=\(models)") }
            if claims > 0 { parts.append("claims=\(claims)") }
            if combineSubscriptions > 0 { parts.append("subscriptions=\(combineSubscriptions)") }
            if stateObservers > 0 { parts.append("stateObservers=\(stateObservers)") }
            if notificationObservers > 0 { parts.append("notifObservers=\(notificationObservers)") }
            if eventMonitors > 0 { parts.append("eventMonitors=\(eventMonitors)") }
            if shrinkTasks > 0 { parts.append("shrinkTasks=\(shrinkTasks)") }
            if pointerSafetyNet { parts.append("pointerSafetyNet") }
            if geometryTask { parts.append("geometryTask") }
            if commandBridge { parts.append("commandBridge") }
            return parts.isEmpty ? "nothing" : parts.joined(separator: " ")
        }
    }

    /// What the controller is currently holding on to.
    var residue: Residue {
        Residue(
            panels: panels.count,
            catchers: hitPanels.count,
            models: models.count,
            claims: models.values.reduce(0) { $0 + $1.claims.count },
            combineSubscriptions: cancellables.count,
            stateObservers: stateObservers.count,
            notificationObservers: observers.count,
            eventMonitors: [mouseMonitor, clickMonitor].compactMap { $0 }.count,
            shrinkTasks: shrinkTasks.count,
            pointerSafetyNet: pointerSafetyTask != nil,
            geometryTask: geometryTask != nil,
            commandBridge: notificationBridge != nil
        )
    }

    var isStarted: Bool { started }

    /// Registers an extra notch for a display that is not physically attached.
    ///
    /// Test-only. Multi-display scoping — "typing in Notes on one screen must
    /// not pin the notch on another" — is otherwise unverifiable on a
    /// single-display Mac, and a check that silently passes because it never
    /// ran is worse than no check. This seeds the same `models`/`panels`
    /// registry production uses, so `closeIfPointerHasLeft` and the claim
    /// validator run their real code over it.
    @discardableResult
    func installSyntheticNotch(id: String, frame: CGRect) -> NotchViewModel {
        let model = NotchViewModel(screenID: id)
        model.willOpen = { [weak self] in self?.prepareCanvasForOpen($0) }
        let panel = NotchPanel(contentRect: frame)
        panel.setFrame(frame, display: false)
        models[id] = model
        panels[id] = panel
        observeModelState()
        return model
    }

    func removeSyntheticNotch(id: String) {
        models[id]?.cancelPending()
        models.removeValue(forKey: id)
        panels[id]?.orderOut(nil)
        panels[id]?.close()
        panels.removeValue(forKey: id)
        observeModelState()
    }

    // MARK: Panel management

    private func primaryScreenID() -> String? {
        let live = connectedScreens()
        if let preferred = settings.preferredScreenID,
           live.contains(where: { $0.stableID == preferred }) {
            return preferred
        }
        if let main = NSScreen.main?.stableID, live.contains(where: { $0.stableID == main }) {
            return main
        }
        return live.first?.stableID
    }

    /// Displays that should currently host a panel.
    private func targetScreens() -> [NSScreen] {
        let live = connectedScreens()
        if settings.showOnAllDisplays {
            return live.filter { NotchGeometry.shouldDisplay(on: $0) }
        }
        guard let id = primaryScreenID(),
              let screen = live.first(where: { $0.stableID == id }) else {
            return []
        }
        return NotchGeometry.shouldDisplay(on: screen) ? [screen] : []
    }

    /// Keeps panel key-status in step with each model's open state.
    private func observeModelState() {
        stateObservers.forEach { $0.cancel() }
        stateObservers.removeAll()
        for model in models.values {
            model.$state
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    // Deferred so the model's own property has already updated.
                    Task { @MainActor in
                        self?.syncKeyStatus()
                        self?.syncPanelExtents()
                        self?.syncInteractivity()
                        self?.updatePointerSafetyNet()
                        self?.syncWingHover()
                    }
                }
                .store(in: &stateObservers)
        }
    }

    func rebuildPanels() {
        let screens = targetScreens()
        let wanted = Set(screens.compactMap(\.stableID))

        // Retire panels for displays that went away or were switched off.
        for (id, panel) in panels where !wanted.contains(id) {
            elevatedSpace?.remove(windowNumber: panel.windowNumber)
            panel.orderOut(nil)
            panel.close()
            panels.removeValue(forKey: id)
            // A claim outlives the window it was made against unless it is
            // released here: unplug a display mid-sentence in Notes and the
            // retired model keeps a .textEditing claim forever. It is dropped
            // from the registry, but any view still holding it — and any later
            // code that consults it — sees a notch that is permanently pinned.
            models[id]?.retire()
            models.removeValue(forKey: id)
        }

        // Catchers are reconciled against `panels` rather than alongside them.
        // Attaching a display can hand us a different stable ID for the same
        // screen as it settles; retiring a panel without its catcher leaves an
        // invisible window sitting on the menu bar, still eating clicks, with
        // nothing left pointing at it.
        for (id, hitPanel) in hitPanels where panels[id] == nil || !wanted.contains(id) {
            hitPanel.orderOut(nil)
            hitPanel.close()
            hitPanels.removeValue(forKey: id)
        }

        for screen in screens {
            guard let id = screen.stableID else { continue }
            if panels[id] == nil {
                let model = NotchViewModel(screenID: id)
                model.willOpen = { [weak self] in self?.prepareCanvasForOpen($0) }
                let panel = makePanel(for: screen, model: model)
                panels[id] = panel
                models[id] = model
            }
            // Exactly one catcher per panel, always.
            if hitPanels[id] == nil, let model = models[id] {
                hitPanels[id] = makeHitPanel(for: model)
            }
            models[id]?.refreshGeometry()
            models[id]?.loggedWindowNumber = panels[id]?.windowNumber ?? 0
            position(panels[id], on: screen)
        }

        applyElevatedSpaceSetting()
        observeModelState()
        syncInteractivity()
        lastScreenSignature = screenSignature()
    }

    private func makePanel(for screen: NSScreen, model: NotchViewModel) -> NotchPanel {
        let size = NotchGeometry.windowSize(for: screen)
        let panel = NotchPanel(contentRect: NSRect(origin: .zero, size: size))

        panel.contentView = Self.makeContentView(for: model, size: size)
        panel.orderFrontRegardless()
        observeKeyFocus(of: panel, model: model)
        return panel
    }

    /// Claims `.textEditing` for exactly the notch whose panel holds key focus.
    ///
    /// Key status is what a focused text field actually depends on, and it is
    /// per-window, so this is naturally scoped to one display. Clicking another
    /// app resigns key and the claim ends on its own.
    private func observeKeyFocus(of panel: NotchPanel, model: NotchViewModel) {
        let owner = UUID()
        let center = NotificationCenter.default
        center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main
        ) { [weak model] _ in
            MainActor.assumeIsolated { model?.claimInteraction(.textEditing, owner: owner) }
        }
        center.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak model] _ in
            MainActor.assumeIsolated { model?.releaseInteraction(.textEditing, owner: owner) }
        }
    }

    /// Builds the panel's content view.
    ///
    /// Shared with the self-test so the click-through behaviour that is asserted
    /// is the behaviour the app actually ships, rather than a hand-rolled
    /// look-alike that can drift.
    static func makeContentView(for model: NotchViewModel, size: CGSize) -> NotchHitTestView {
        let host = NSHostingView(
            rootView: NotchRootView(model: model).environmentObject(Settings.shared)
        )
        // Without this the hosting view propagates its content's ideal size up
        // to the window, which silently widens the panel and knocks the notch
        // off centre. The controller owns the panel geometry, not SwiftUI.
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]

        // Everything outside the drawn notch must fall through to the app
        // underneath — see NotchHitTestView.
        let container = NotchHitTestView(frame: NSRect(origin: .zero, size: size))
        container.autoresizingMask = [.width, .height]
        container.addSubview(host)
        container.interactiveRegion = { [weak model, weak container] in
            guard let model, let container else { return .zero }
            return NotchWindowController.interactiveRegion(for: model, in: container.bounds)
        }
        return container
    }

    /// Builds the interactive catcher.
    ///
    /// Not private: the self-test drives this exact panel so the hover path it
    /// asserts is the one the app ships.
    func makeHitPanel(for model: NotchViewModel) -> NotchHitPanel {
        let panel = NotchHitPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10))
        let view = NotchHitView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.autoresizingMask = [.width, .height]

        view.onHoverChange = { [weak model] hovering in
            guard let model, !NotchWindowController.shared.ignoresLiveInput else { return }
            model.isHovering = hovering
            if hovering {
                model.scheduleOpen()
            } else {
                // Leaving clears the "stay shut" latch set by an explicit close.
                model.allowHoverToReopen()
                // Abandon an open that has not fired yet — this is what makes a
                // pointer merely passing over the notch harmless. Once the notch
                // is actually open the panel owns hover, and closing is its job:
                // the pointer has moved *into* the panel, not away from it.
                if model.state == .closed { model.cancelPending() }
            }
        }
        view.onClick = { [weak model] in
            guard let model, Settings.shared.openTrigger.allowsClick else { return }
            model.toggle(source: .trackingArea)
        }
        let dragOwner = UUID()
        view.onDragEnter = { [weak model] in
            guard let model, Settings.shared.shelfAutoExpandOnDrag else { return }
            model.page = .tray
            model.claimInteraction(.dragging, owner: dragOwner)
            model.open(source: .drag)
        }
        // Explicit release. Validation also drops this claim once no button is
        // held, so a drag cancelled off-screen cannot leave the notch pinned.
        view.onDragEnd = { [weak model] in
            guard let model else { return }
            model.releaseInteraction(.dragging, owner: dragOwner)
            model.isDragTargeting = false
        }

        panel.contentView = view
        panel.orderFrontRegardless()
        return panel
    }

    /// Places the catcher over the collapsed notch only.
    private func positionHitPanel(_ id: String, on screen: NSScreen) {
        guard let panel = hitPanels[id], let model = models[id] else { return }
        let height = model.effectiveClosedHeight
        guard height > 0, !model.isSuppressed else {
            panel.setFrame(.zero, display: false)
            panel.orderOut(nil)
            return
        }
        let width = NotchShape.totalWidth(
            forBody: model.closedSize.width, topRadius: settings.closedCornerRadius
        )
        // Slop below the notch makes the top screen edge easier to hit. Height
        // only: a wider catcher would start swallowing menu-bar clicks, which
        // is the defect this two-window split exists to avoid.
        let size = CGSize(width: width, height: height + max(0, settings.hoverPadding))
        panel.setFrame(
            NSRect(
                origin: NotchGeometry.windowOrigin(on: screen, windowSize: size),
                size: size
            ),
            display: false
        )
        panel.orderFrontRegardless()
    }

    /// Closes a notch the pointer has already left.
    ///
    /// Hover is driven by tracking areas, which is the right mechanism, but
    /// `mouseExited` is not guaranteed to arrive when a *window* moves out from
    /// under a stationary pointer — a display change, a live activity resizing
    /// the panel, or the notch collapsing can all move it. When that event is
    /// missed the notch stays open with the pointer nowhere near it.
    ///
    /// This is a fallback, not the mechanism: it ticks once a second and only
    /// while something is open, so an idle Mac does no work.
    /// Starts or stops the recovery check to match the current state.
    ///
    /// Stopping eagerly — rather than letting the loop notice on its next tick —
    /// means an idle Mac is never left with a pending timer, and makes the
    /// behaviour observable immediately instead of up to a second later.
    private func updatePointerSafetyNet() {
        if models.values.contains(where: { $0.state == .open }) {
            startPointerSafetyNet()
        } else {
            pointerSafetyTask?.cancel()
            pointerSafetyTask = nil
        }
    }

    private func startPointerSafetyNet() {
        guard pointerSafetyTask == nil else { return }
        // Only tick while something is actually open. `observeModelState` fires
        // on subscribe, so without this the net would start at launch and poll
        // an idle Mac forever.
        guard models.values.contains(where: { $0.state == .open }) else { return }
        pointerSafetyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                guard self.models.values.contains(where: { $0.state == .open }) else {
                    self.pointerSafetyTask = nil
                    return
                }
                // The timer reads the *real* pointer, so it is live input like
                // any other and belongs behind the same door. Tests that want
                // the recovery pass drive it explicitly through
                // `runPointerSafetyCheckNow()`, which is unaffected — the timer
                // firing on its own schedule with the real pointer position was
                // closing notches mid-assertion about one deterministic run in
                // four.
                guard !self.ignoresLiveInput else { continue }
                self.closeIfPointerHasLeft()
            }
        }
    }

    /// Interaction states the fallback must never interrupt.
    ///
    /// The pointer legitimately leaves the panel during all of these — typing in
    /// Notes while looking elsewhere, picking from a menu, dragging a file in —
    /// and closing the notch underneath the user would be worse than the missed
    /// event this exists to recover from.
    /// A sheet or alert genuinely blocks the whole app, so it is the one
    /// condition that legitimately applies to every notch at once. It is also
    /// inherently transient — it cannot pin anything indefinitely.
    private var isApplicationModal: Bool { NSApp.modalWindow != nil }

    /// Whether a menu or popover is currently on screen.
    ///
    /// Their classes are private, so the class name is the available signal.
    /// Deliberately *not* used as a blanket guard: it feeds the `.menu` claim,
    /// which is attributed to a notch and revalidated, so a menu that vanishes
    /// without notice cannot leave anything pinned.
    private var isMenuOnScreen: Bool {
        NSApp.windows.contains { window in
            guard window.isVisible else { return false }
            let name = window.className
            return name.contains("Menu") || name.contains("Popover")
        }
    }

    /// Drops claims whose premise no longer holds.
    ///
    /// Explicit release is the normal path; this catches the cases where it can
    /// be missed — a drag cancelled off-screen, a window that disappeared, a
    /// menu dismissed by clicking elsewhere. Nothing expires on a clock, only on
    /// its own condition going away.
    /// Whether the panel for a display currently holds key focus.
    ///
    /// Injectable for the same reason pointer position, button state, display
    /// configuration and scheduling are. A text-editing claim survives exactly
    /// as long as its panel is key, and two checks in the suite need opposite
    /// answers to that: one asserts a claim holds the notch open while typing,
    /// the other asserts it is dropped once nothing sustains it. Both were
    /// reading whatever the window server happened to be doing, so both were
    /// really asserting that the machine was in a convenient mood — and the
    /// first of them failed about once in ten runs, reported as a product
    /// defect. Nil means production behaviour: ask the window.
    var panelHoldsKeyFocus: ((String) -> Bool)?

    private func panelIsKey(_ id: String) -> Bool {
        if let panelHoldsKeyFocus { return panelHoldsKeyFocus(id) }
        return panels[id]?.isKeyWindow ?? false
    }

    private func validateInteractionClaims() {
        let menuOnScreen = isMenuOnScreen
        let buttonDown = mouseButtonsAreDown()

        for (id, model) in models {
            // Text editing lasts exactly as long as this display's panel holds
            // key focus. Another app becoming key ends it immediately.
            if !panelIsKey(id) {
                model.releaseInteractions(of: .textEditing)
            }
            // A drag needs a button held down. Releasing the mouse anywhere —
            // including outside the panel — ends the claim, so a cancelled drag
            // cannot leave the notch pinned.
            if !buttonDown {
                model.releaseInteractions(of: .dragging)
                if model.isDragTargeting { model.isDragTargeting = false }
            }
            if !menuOnScreen {
                model.releaseInteractions(of: .menu)
            }
        }

        // A menu is raised from somewhere; attribute it to the notch under the
        // pointer, not to every display.
        if menuOnScreen, let (id, _) = modelUnderPointer() {
            models[id]?.claimInteraction(.menu, owner: Self.menuOwner)
        }
    }

    /// Stable owner token for the menu claim, which has no natural owner object.
    private static let menuOwner = UUID()

    /// Whether a mouse button is currently held.
    ///
    /// Injectable so a drag can be simulated: a real drag always has a button
    /// down, and without this seam a test can only exercise the *stale* case and
    /// would wrongly conclude that live drags get interrupted.
    var mouseButtonsAreDown: () -> Bool = { NSEvent.pressedMouseButtons != 0 }

    /// Suppresses every *live* input path into the notch.
    ///
    /// The deterministic suite injects pointer position, button state, display
    /// configuration and scheduling — but two paths were never injected and
    /// stayed wired to the real machine: the global click monitor, and the
    /// tracking areas on the real panels. So a click or a pointer movement by
    /// somebody actually using the Mac closed notches mid-assertion, and checks
    /// that had run clean for hundreds of unattended runs began failing the
    /// moment a person was at the keyboard. The failures looked like product
    /// defects — "an open notch schedules the recovery check", attributed to
    /// `outsideClick` — and were nothing of the kind.
    ///
    /// "Deterministic" has to mean it, so the suite closes these two doors for
    /// its duration rather than hoping nobody touches the machine.
    var ignoresLiveInput = false

    /// Where the pointer is.
    ///
    /// Injectable for the same reason as `mouseButtonsAreDown`: recovery from a
    /// missed crossing is defined entirely in terms of "the pointer is not near
    /// the panel", and a test that cannot move the pointer can otherwise only
    /// verify that rule when the tester's hand happens to be somewhere useful.
    /// With this seam the recovery postcondition is a hard gate on every run
    /// instead of something that depends on live machine state.
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }

    private func modelUnderPointer() -> (String, NotchViewModel)? {
        let mouse = pointerLocation()
        return models.first { id, _ in
            NSScreen.screen(withStableID: id)?.frame.contains(mouse) ?? false
        }
    }

    /// Whether the recovery check is currently scheduled. Must be false when
    /// nothing is open, or the app would tick forever on an idle Mac.
    var pointerSafetyNetIsRunning: Bool { pointerSafetyTask != nil }

    /// Runs one recovery pass immediately. Lets tests drive the fallback
    /// deterministically instead of waiting on its one-second cadence.
    func runPointerSafetyCheckNow() { closeIfPointerHasLeft() }

    /// True when the fallback would decline to act on `model` right now.
    func fallbackIsHoldingOff(for model: NotchViewModel) -> Bool {
        isApplicationModal || model.isInteracting || model.isDragTargeting
    }

    /// Kept for the pointer-fallback test's coarse check.
    var fallbackIsHoldingOff: Bool {
        isApplicationModal || models.values.contains { $0.isInteracting }
    }

    /// Runs claim validation on demand, for tests.
    func validateClaimsNow() { validateInteractionClaims() }

    private func closeIfPointerHasLeft() {
        validateInteractionClaims()
        // The only genuinely app-wide hold-off left.
        guard !isApplicationModal else { return }

        let mouse = pointerLocation()
        for (id, model) in models where model.state == .open {
            // Scoped to this notch: interaction on one display never pins
            // another, and Settings taking focus pins nothing at all.
            guard !model.isInteracting else { continue }
            guard !model.isDragTargeting else { continue }
            guard let panel = panels[id] else { continue }
            // A generous margin: this must never fight legitimate hover, only
            // catch a pointer that is clearly elsewhere.
            let region = panel.frame.insetBy(dx: -24, dy: -24)
            if !region.contains(mouse) { model.scheduleClose(source: .pointerFallback) }
        }
    }

    /// Exactly one of the two windows accepts input at a time.
    ///
    /// Collapsed, the wide drawing panel is completely inert and only the tiny
    /// catcher takes events, so the rest of the menu bar stays clickable.
    /// Expanded, the panel is visible and covers real content, so it takes over.
    private func syncInteractivity() {
        for (id, model) in models {
            let isOpen = model.state == .open
            panels[id]?.ignoresMouseEvents = !isOpen
            hitPanels[id]?.ignoresMouseEvents = isOpen
        }
    }

    /// The part of the panel that accepts clicks, in panel coordinates.
    ///
    /// Collapsed, this is only the notch itself — deliberately *not* the live
    /// activity "wings", which are display-only. Those sit over the menu bar,
    /// and making them clickable would block menu-bar items for as long as
    /// something was playing.
    static func interactiveRegion(for model: NotchViewModel, in bounds: NSRect) -> NSRect {
        guard !model.isSuppressed else { return .zero }

        if model.state == .open {
            let size = NotchGeometry.openSize
            let width = size.width + Settings.shared.openCornerRadius * 2
            return NSRect(
                x: bounds.midX - width / 2,
                y: bounds.maxY - size.height,
                width: width,
                height: size.height
            )
        }

        let height = model.effectiveClosedHeight
        guard height > 0 else { return .zero }
        let width = NotchShape.totalWidth(
            forBody: model.closedSize.width,
            topRadius: Settings.shared.closedCornerRadius
        )
        return NSRect(
            x: bounds.midX - width / 2,
            y: bounds.maxY - height,
            width: width,
            height: height
        )
    }

    private func position(_ panel: NotchPanel?, on screen: NSScreen) {
        guard let panel else { return }
        let model = screen.stableID.flatMap { models[$0] }
        let size = model.map { panelSize(for: $0, on: screen) } ?? NotchGeometry.windowSize(for: screen)
        if panel.frame.size != size {
            panel.setContentSize(size)
        }
        panel.setFrameOrigin(NotchGeometry.windowOrigin(on: screen, windowSize: size))
        if let id = screen.stableID { positionHitPanel(id, on: screen) }
    }

    private func panelSize(for model: NotchViewModel, on screen: NSScreen) -> CGSize {
        let id = screen.stableID ?? ""
        // `expandingCanvas` is the opening counterpart of `shrinkTasks`: the
        // former holds the wide canvas from just before the open begins, the
        // latter holds it until well after the close ends. Between them the
        // window is the same size for the whole of both animations.
        if model.state == .open || shrinkTasks[id] != nil || expandingCanvas.contains(id) {
            return NotchGeometry.windowSize(for: screen)
        }
        return NotchGeometry.collapsedWindowSize(
            closed: model.closedSize,
            hasActivity: LiveActivityCenter.shared.current != nil || HUDController.shared.state != nil,
            expandedActivity: LiveActivityCenter.shared.trailingExpanded
        )
    }

    /// Displays whose panel has been given the open canvas ahead of the
    /// animation, and has not shrunk back yet.
    private var expandingCanvas: Set<String> = []

    /// Gives a panel its full canvas before the opening animation starts.
    ///
    /// Collapsed, the window is only as wide as the notch — there is no point
    /// owning menu-bar space nobody is using. That makes the first frames of an
    /// open a race: the SwiftUI content starts growing towards the open size
    /// while the window it is drawn in is still notch-sized, and the window
    /// only catches up a runloop turn or two later, resizing *and* re-centring
    /// in one step. On a recording the shell jumped 200pt left on the first
    /// frame and then grew rightward from a fixed left edge.
    ///
    /// Closing never had this problem because it holds the wide canvas for
    /// 550ms after the state changes. This is that arrangement, mirrored:
    /// widen first, animate second.
    func prepareCanvasForOpen(_ model: NotchViewModel) {
        guard let id = model.screenID, let panel = panels[id],
              let screen = NSScreen.screen(withStableID: id)
        else { return }
        shrinkTasks[id]?.cancel(); shrinkTasks[id] = nil
        expandingCanvas.insert(id)
        // Only the drawing panel, deliberately — not `position(_:on:)`, which
        // also re-frames the catcher and calls `orderFrontRegardless` on it.
        // Re-ordering windows in the same breath as starting the animation is
        // exactly the kind of side effect this is trying to get away from.
        let size = NotchGeometry.windowSize(for: screen)
        if panel.frame.size != size { panel.setContentSize(size) }
        panel.setFrameOrigin(NotchGeometry.windowOrigin(on: screen, windowSize: size))
    }

    /// Resize only at transition boundaries, never once per animation frame.
    /// The wide canvas survives the closing animation, then relinquishes menu-bar space.
    private func syncPanelExtents() {
        for (id, model) in models {
            guard let screen = NSScreen.screen(withStableID: id) else { continue }
            if model.state == .open {
                shrinkTasks[id]?.cancel(); shrinkTasks[id] = nil
                position(panels[id], on: screen)
            } else if (panels[id]?.frame.height ?? 0) > model.closedSize.height + 3 {
                guard shrinkTasks[id] == nil else { continue }
                shrinkTasks[id] = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(550))
                    guard !Task.isCancelled, let self else { return }
                    self.shrinkTasks[id] = nil
                    guard self.models[id]?.state == .closed else { return }
                    self.expandingCanvas.remove(id)
                    self.position(self.panels[id], on: screen)
                }
            } else {
                expandingCanvas.remove(id)
                position(panels[id], on: screen)
            }
        }
    }

    // MARK: The trailing indicator's hover

    /// Polled, not tracked.
    ///
    /// The activity wings are drawn in the wide panel, which ignores mouse
    /// events by design: it spans menu-bar space, and anything it accepts is a
    /// click the menu bar does not get. That is the whole reason for the
    /// two-window split, so putting a tracking area on the wing would undo it.
    /// Reading the pointer's position asks nothing of the window server and
    /// changes no window's behaviour. It runs only while there is an indicator
    /// to expand, and stops the moment there is not.
    private var wingHoverTimer: Timer?

    private func syncWingHover() {
        let wanted = !AppInfo.isSelfTest && !ignoresLiveInput
            && LiveActivityCenter.shared.current.map(ClosedActivityView.canExpand) == true
            && models.values.contains { $0.state == .closed }
        if wanted, wingHoverTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateWingHover() }
            }
            RunLoop.main.add(timer, forMode: .common)
            wingHoverTimer = timer
        } else if !wanted, wingHoverTimer != nil {
            wingHoverTimer?.invalidate()
            wingHoverTimer = nil
            LiveActivityCenter.shared.setTrailingExpanded(false)
        }
    }

    private func updateWingHover() {
        guard !ignoresLiveInput else { return }
        let mouse = pointerLocation()
        let inside = models.contains { id, model in
            guard model.state == .closed,
                  let screen = NSScreen.screen(withStableID: id) else { return false }
            return trailingWingRect(for: model, on: screen).contains(mouse)
        }
        LiveActivityCenter.shared.setTrailingExpanded(inside)
    }

    /// Where the trailing wing is drawn, in screen coordinates.
    ///
    /// Grows once expanded, so the pointer does not fall off the thing it just
    /// opened and set off a flicker between the two widths.
    func trailingWingRect(for model: NotchViewModel, on screen: NSScreen) -> CGRect {
        let width = LiveActivityCenter.shared.trailingExpanded
            ? ClosedActivityView.expandedTrailingWidth
            : ClosedActivityView.trailingWidth
        // The same couple of points of slop the notch's own hover region uses.
        let height = max(model.effectiveClosedHeight, 4) + 3
        let frame = screen.frame
        return CGRect(
            x: frame.midX + model.closedSize.width / 2,
            y: frame.maxY - height,
            width: width,
            height: height
        )
    }

    var panelFrames: [CGRect] { panels.values.map(\.frame) }

    func repositionAll() {
        for (id, panel) in panels {
            guard let screen = NSScreen.screen(withStableID: id) else { continue }
            models[id]?.refreshGeometry()
            position(panel, on: screen)
        }
    }

    private func teardownPanels() {
        for panel in panels.values {
            elevatedSpace?.remove(windowNumber: panel.windowNumber)
            panel.orderOut(nil)
            panel.close()
        }
        for panel in hitPanels.values {
            panel.orderOut(nil)
            panel.close()
        }
        hitPanels.removeAll()
        panels.removeAll()
        models.values.forEach { $0.retire() }
        models.removeAll()
        elevatedSpace = nil
    }

    /// Opt-in private-API path that raises the panel above full-screen spaces.
    private func applyElevatedSpaceSetting() {
        if settings.useElevatedSpace {
            if elevatedSpace == nil { elevatedSpace = ElevatedWindowSpace() }
            panels.values.forEach { elevatedSpace?.add(windowNumber: $0.windowNumber) }
        } else if elevatedSpace != nil {
            panels.values.forEach { elevatedSpace?.remove(windowNumber: $0.windowNumber) }
            elevatedSpace = nil
        }
    }

    // MARK: Key status

    /// Panels take key status only while open, so background clicks never steal
    /// focus from the user's frontmost app.
    private func syncKeyStatus() {
        for (id, panel) in panels {
            let open = models[id]?.state == .open
            panel.allowsKeyStatus = open
            if !open, panel.isKeyWindow {
                panel.resignKey()
            }
        }
    }

    // MARK: Event monitoring

    /// Installs the *optional* global click monitor.
    ///
    /// Hover is handled by `HoverTracker`'s tracking areas, which need no
    /// permission — see the note at the top of HoverTracker.swift. Global
    /// monitors only fire once Accessibility has been granted, so nothing
    /// essential may depend on them. This one adds "click somewhere else to
    /// collapse"; without it, moving the pointer off the notch still closes it.
    private func installEventMonitors() {
        removeEventMonitors()

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.handleGlobalClick() }
        }
    }

    /// Whether the optional click-outside-to-collapse enhancement is active.
    var globalClickMonitoringAvailable: Bool { AXIsProcessTrusted() }

    private func removeEventMonitors() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        mouseMonitor = nil
        clickMonitor = nil
    }

    /// Hit region for hover: the closed notch when collapsed, the whole panel
    /// (minus the shadow gutter) when open.
    private func hoverRegion(for model: NotchViewModel, on screen: NSScreen) -> CGRect {
        let frame = screen.frame
        if model.state == .open {
            let size = NotchGeometry.openSize
            return CGRect(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height,
                width: size.width,
                height: size.height
            )
        }
        let size = model.closedSize
        // A couple of points of slop makes the top screen edge easier to hit.
        return CGRect(
            x: frame.midX - size.width / 2,
            y: frame.maxY - max(size.height, 4),
            width: size.width,
            height: max(size.height, 4)
        )
    }

    private func handleGlobalClick() {
        guard !ignoresLiveInput else { return }
        let mouse = pointerLocation()
        for (id, model) in models {
            guard let screen = NSScreen.screen(withStableID: id) else { continue }
            let inside = hoverRegion(for: model, on: screen).contains(mouse)
            if inside {
                if settings.openTrigger.allowsClick { model.toggle(source: .outsideClick) }
            } else if model.state == .open {
                model.close(source: .outsideClick)
            }
        }
        syncKeyStatus()
    }

    // MARK: System events

    private func screenSignature() -> String {
        NSScreen.screens
            .map { "\($0.stableID ?? "?"):\(Int($0.frame.width))x\(Int($0.frame.height))@\($0.backingScaleFactor)" }
            .sorted()
            .joined(separator: "|")
    }

    private func observe(_ center: NotificationCenter, forName name: Notification.Name,
                         object: Any?, queue: OperationQueue?,
                         using handler: @escaping @Sendable (Notification) -> Void) {
        observers.append((center, center.addObserver(forName: name, object: object, queue: queue, using: handler)))
    }

    private func observeSystemEvents() {
        let center = NotificationCenter.default

        observe(center,
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScreenParametersChanged() }
        }

        observe(center, forName: .notchGeometryChanged, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildPanels()
                self?.repositionAll()
            }
        }

        observe(center, forName: .escapePressedInNotch, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.allModels.forEach { $0.close(source: .escape) } }
        }

        // Wake and unlock both need a reposition: display geometry can change
        // while the machine is asleep.
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace,
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }
        observe(workspace,
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.repositionAll() }
        }

        // Scriptable control, so a Shortcut, an Automation action or a shell
        // one-liner can drive the notch without needing Accessibility.
        //
        // Registration goes through a *nonisolated* bridge object.
        // `DistributedNotificationCenter` invokes its selector through the
        // Objective-C runtime; pointing that at a main-actor-isolated method
        // does not work under `defaultIsolation(MainActor.self)`. The bridge is
        // plain Obj-C-visible and hops to the main actor itself.
        //
        // `suspensionBehavior: .deliverImmediately` is also essential: the
        // default holds notifications for an app the system considers
        // suspended, which an accessory app that is never frontmost always is.
        notificationBridge = DistributedCommandBridge { command in
            // The bridge already hops to the main queue; assume that isolation.
            MainActor.assumeIsolated {
                NotchWindowController.shared.perform(command)
            }
        }
        notificationBridge?.register()
    }

    /// Applies a scripted command to the notch on the display under the pointer.
    func perform(_ command: NotchCommand) {
        switch command {
        case .screenLocked: setLocked(true); return
        case .screenUnlocked: setLocked(false); return
        case .openEverywhere:
            models.values.forEach { $0.open(source: .explicitCommand) }
            syncKeyStatus()
            updatePointerSafetyNet()
            return
        default: break
        }
        guard !isScreenLocked, let model = activeModel else { return }
        switch command {
        case .toggle: model.toggle(source: .explicitCommand)
        case .open: model.open(source: .explicitCommand)
        case .close: model.close(source: .explicitCommand)
        case let .show(page):
            model.page = page
            model.focusedTool = nil
            model.open(source: .explicitCommand)
        case .screenLocked: setLocked(true)
        case .screenUnlocked: setLocked(false)
        // Handled above, before a single active model is resolved.
        case .openEverywhere: break
        }
        syncKeyStatus()
        syncPanelExtents()
    }

    private func handleScreenParametersChanged() {
        // Coalesce the burst of notifications macOS emits while a display is
        // being attached, then rebuild once things settle.
        let signature = screenSignature()
        guard signature != lastScreenSignature else {
            repositionAll()
            return
        }
        geometryTask?.cancel()
        geometryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, self.started else { return }
            self.rebuildPanels()
            self.repositionAll()
        }
    }

    private func handleWake() {
        geometryTask?.cancel()
        geometryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, self.started else { return }
            self.allModels.forEach { $0.close(source: .systemState) }
            self.rebuildPanels()
            self.repositionAll()
        }
    }

    private func setLocked(_ locked: Bool) {
        isScreenLocked = locked
        if locked {
            allModels.forEach { $0.close(source: .systemState) }
            panels.values.forEach { $0.orderOut(nil) }
        } else {
            panels.values.forEach { $0.orderFrontRegardless() }
            repositionAll()
        }
    }
}
