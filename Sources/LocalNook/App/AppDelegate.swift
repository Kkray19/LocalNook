//
//  AppDelegate.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private let settings = Settings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory: no Dock icon, no app menu — LocalNook lives in the notch.
        NSApp.setActivationPolicy(.accessory)

        NotchWindowController.shared.start()
        configureStatusItem()

        // Event-driven monitors. None of these poll while idle.
        _ = BatteryMonitor.shared
        _ = AudioDeviceMonitor.shared
        LiveActivityCenter.shared.start()
        SessionMonitor.shared.start()
        HUDController.shared.start()
        FullscreenDetector.shared.syncWithSettings()

        NotificationCenter.default.addObserver(
            forName: .openSettingsRequested, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SettingsWindowController.shared.show() }
        }

        // The menu bar icon can be toggled from Settings at any time.
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.syncStatusItemVisibility()
                FullscreenDetector.shared.syncWithSettings()
            }
            .store(in: &cancellables)

        if !settings.hasCompletedFirstRun {
            settings.hasCompletedFirstRun = true
            SettingsWindowController.shared.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotchWindowController.shared.stop()
        cancellables.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: Status item

    private func configureStatusItem() {
        guard settings.showMenuBarIcon else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage.localNookGlyph(pointSize: 15)
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "LocalNook"

        let menu = NSMenu()
        menu.addItem(
            withTitle: "Toggle Notch", action: #selector(toggleNotch), keyEquivalent: "n"
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ","
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit LocalNook", action: #selector(quit), keyEquivalent: "q"
        ).target = self
        item.menu = menu
        statusItem = item
    }

    private func syncStatusItemVisibility() {
        if settings.showMenuBarIcon, statusItem == nil {
            configureStatusItem()
        } else if !settings.showMenuBarIcon, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func toggleNotch() {
        NotchWindowController.shared.activeModel?.toggle()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
