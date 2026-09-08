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
        rebuildPanels()
        installEventMonitors()
        observeSystemEvents()
        LiveActivityCenter.shared.$current.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncPanelExtents() }.store(in: &cancellables)
        HUDController.shared.$state.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncPanelExtents() }.store(in: &cancellables)
        settings.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] in self?.rebuildPanels() }.store(in: &cancellables)
    }

    func stop() {
        started = false
        cancellables.removeAll()
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
        let mouse = NSEvent.mouseLocation
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

    // MARK: Panel management

    private func primaryScreenID() -> String? {
        if let preferred = settings.preferredScreenID,
           NSScreen.screen(withStableID: preferred) != nil {
            return preferred
        }
        return NSScreen.main?.stableID ?? NSScreen.screens.first?.stableID
    }

    /// Displays that should currently host a panel.
    private func targetScreens() -> [NSScreen] {
        if settings.showOnAllDisplays {
            return NSScreen.screens.filter { NotchGeometry.shouldDisplay(on: $0) }
        }
        guard let id = primaryScreenID(), let screen = NSScreen.screen(withStableID: id) else {
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
            models[id]?.cancelPending()
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
                let panel = makePanel(for: screen, model: model)
                panels[id] = panel
                models[id] = model
            }
            // Exactly one catcher per panel, always.
            if hitPanels[id] == nil, let model = models[id] {
                hitPanels[id] = makeHitPanel(for: model)
            }
            models[id]?.refreshGeometry()
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
        return panel
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
            guard let model else { return }
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
            model.toggle()
        }
        view.onDragEnter = { [weak model] in
            guard let model, Settings.shared.shelfAutoExpandOnDrag else { return }
            model.page = .tray
            model.open()
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
        // A few points of slop makes the very top screen edge easier to hit.
        let size = CGSize(width: width, height: height + 3)
        panel.setFrame(
            NSRect(
                origin: NotchGeometry.windowOrigin(on: screen, windowSize: size),
                size: size
            ),
            display: false
        )
        panel.orderFrontRegardless()
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
        if model.state == .open || shrinkTasks[screen.stableID ?? ""] != nil {
            return NotchGeometry.windowSize(for: screen)
        }
        return NotchGeometry.collapsedWindowSize(closed: model.closedSize,
            hasActivity: LiveActivityCenter.shared.current != nil || HUDController.shared.state != nil)
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
                    self.position(self.panels[id], on: screen)
                }
            } else {
                position(panels[id], on: screen)
            }
        }
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
        models.values.forEach { $0.cancelPending() }
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
        let mouse = NSEvent.mouseLocation
        for (id, model) in models {
            guard let screen = NSScreen.screen(withStableID: id) else { continue }
            let inside = hoverRegion(for: model, on: screen).contains(mouse)
            if inside {
                if settings.openTrigger.allowsClick { model.toggle() }
            } else if model.state == .open {
                model.close()
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
            MainActor.assumeIsolated { self?.allModels.forEach { $0.close() } }
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
        default: break
        }
        guard !isScreenLocked, let model = activeModel else { return }
        switch command {
        case .toggle: model.toggle()
        case .open: model.open()
        case .close: model.close()
        case let .show(page):
            model.page = page
            model.focusedTool = nil
            model.open()
        case .screenLocked: setLocked(true)
        case .screenUnlocked: setLocked(false)
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
            self.allModels.forEach { $0.close() }
            self.rebuildPanels()
            self.repositionAll()
        }
    }

    private func setLocked(_ locked: Bool) {
        isScreenLocked = locked
        if locked {
            allModels.forEach { $0.close() }
            panels.values.forEach { $0.orderOut(nil) }
        } else {
            panels.values.forEach { $0.orderFrontRegardless() }
            repositionAll()
        }
    }
}
