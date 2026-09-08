//
//  SettingsWindowController.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import AppKit
import SwiftUI

/// Hosts the settings window. LocalNook is an accessory app, so it temporarily
/// becomes a regular app while settings are open in order to get a normal
/// window, menu bar and keyboard focus — then drops back to accessory.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private override init() { super.init() }

    func show() {
        if window == nil { window = makeWindow() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "LocalNook Settings"
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: SettingsView().environmentObject(Settings.shared)
        )
        window.identifier = NSUserInterfaceItemIdentifier("LocalNookSettings")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Back to accessory so the Dock icon disappears again.
        NSApp.setActivationPolicy(.accessory)
    }
}
