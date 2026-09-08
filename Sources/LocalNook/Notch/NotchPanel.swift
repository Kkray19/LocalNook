//
//  NotchPanel.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import AppKit
import SwiftUI

/// The borderless panel that hosts the notch UI.
///
/// It is deliberately *non-activating*: clicking it must never pull focus away
/// from whatever the user is working in. The one exception is text entry
/// (Notes, To-Do), which needs key status — so `canBecomeKey` is gated on the
/// notch actually being open.
final class NotchPanel: NSPanel {
    /// Set by the controller so the panel only accepts key status while open.
    var allowsKeyStatus: Bool = false

    override var canBecomeKey: Bool { allowsKeyStatus }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // Above the menu bar, below screen-saver/alert levels.
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false          // the SwiftUI layer draws its own shadow
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isRestorable = false
        // Excludes the panel from window lists and screen sharing pickers.
        sharingType = .none
    }

    /// Escape collapses the notch rather than beeping.
    override func cancelOperation(_ sender: Any?) {
        guard Settings.shared.closeOnEscape else { return }
        NotificationCenter.default.post(name: .escapePressedInNotch, object: self)
    }
}

extension Notification.Name {
    static let escapePressedInNotch = Notification.Name("LocalNook.escapeInNotch")
}
