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

final class NotchWindowController: NSObject {
    static let shared = NotchWindowController()

    private var panels: [String: NotchPanel] = [:]
    private var models: [String: NotchViewModel] = [:]
    private var mouseMonitor: Any?
    private var clickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var stateObservers = Set<AnyCancellable>()
    private var isScreenLocked = false
    private var lastScreenSignature: String = ""

    /// Only used when `useElevatedSpace` is on; see ARCHITECTURE.md § Private APIs.
    private var elevatedSpace: ElevatedWindowSpace?

    private let settings = Settings.shared

    private override init() { super.init() }

    // MARK: Lifecycle

    func start() {
        rebuildPanels()
        installEventMonitors()
        observeSystemEvents()
    }

    func stop() {
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
                    Task { @MainActor in self?.syncKeyStatus() }
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
            models.removeValue(forKey: id)
        }

        for screen in screens {
            guard let id = screen.stableID else { continue }
            if panels[id] == nil {
                let model = NotchViewModel(screenID: id)
                let panel = makePanel(for: screen, model: model)
                panels[id] = panel
                models[id] = model
            }
            models[id]?.refreshGeometry()
            position(panels[id], on: screen)
        }

        applyElevatedSpaceSetting()
        observeModelState()
        lastScreenSignature = screenSignature()
    }

    private func makePanel(for screen: NSScreen, model: NotchViewModel) -> NotchPanel {
        let size = NotchGeometry.windowSize(for: screen)
        let panel = NotchPanel(contentRect: NSRect(origin: .zero, size: size))
        let host = NSHostingView(
            rootView: NotchRootView(model: model).environmentObject(settings)
        )
        // Without this the hosting view propagates its content's ideal size up
        // to the window, which silently widens the panel and knocks the notch
        // off centre. The controller owns the panel geometry, not SwiftUI.
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.orderFrontRegardless()
        return panel
    }

    private func position(_ panel: NotchPanel?, on screen: NSScreen) {
        guard let panel else { return }
        let size = NotchGeometry.windowSize(for: screen)
        if panel.frame.size != size {
            panel.setContentSize(size)
        }
        panel.setFrameOrigin(NotchGeometry.windowOrigin(on: screen, windowSize: size))
    }

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
        panels.removeAll()
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

    private func observeSystemEvents() {
        let center = NotificationCenter.default

        center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScreenParametersChanged() }
        }

        center.addObserver(forName: .notchGeometryChanged, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildPanels()
                self?.repositionAll()
            }
        }

        center.addObserver(forName: .escapePressedInNotch, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.allModels.forEach { $0.close() } }
        }

        // Wake and unlock both need a reposition: display geometry can change
        // while the machine is asleep.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }
        workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.repositionAll() }
        }

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLocked(true) }
        }
        distributed.addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLocked(false) }
        }
    }

    private func handleScreenParametersChanged() {
        // Coalesce the burst of notifications macOS emits while a display is
        // being attached, then rebuild once things settle.
        let signature = screenSignature()
        guard signature != lastScreenSignature else {
            repositionAll()
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self else { return }
            self.rebuildPanels()
            self.repositionAll()
        }
    }

    private func handleWake() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self else { return }
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
