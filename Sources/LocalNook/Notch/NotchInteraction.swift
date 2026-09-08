//
//  NotchInteraction.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Explicit ownership of "do not close this notch yet".
//
//  The previous guards were a set of global conditions consulted at close time:
//  any of our windows being key, any mouse button anywhere being down, any menu
//  anywhere on screen. They stopped the recovery fallback interrupting the user,
//  but they had three faults:
//
//    * They were app-wide. Typing in the built-in display's notch suppressed
//      closing on the external one, and opening Settings pinned every notch on
//      every display for as long as it stayed focused.
//    * They had no owner. Nothing was responsible for ending them, so a
//      condition that got stuck stayed stuck.
//    * They could not be reasoned about. "Is a menu open somewhere?" is not a
//      statement about a particular notch.
//
//  A claim is taken by a specific owner, against a specific notch, for a stated
//  reason. It is released explicitly, and — because explicit release can be
//  missed when a drag is cancelled or a window disappears — it is also revalidated
//  against its own condition and dropped when that condition no longer holds.
//  That is not a timeout: nothing expires on a clock, only on its premise.
//

import Foundation

/// Why a notch is being held open.
enum NotchInteraction: String, Sendable, CaseIterable {
    /// A text field inside the panel has keyboard focus.
    case textEditing
    /// A drag is in flight over this notch.
    case dragging
    /// A menu or popover raised from this notch is on screen.
    case menu

    var label: String { rawValue }
}

/// One outstanding reason, and who is responsible for ending it.
struct NotchInteractionClaim: Hashable, Sendable {
    let kind: NotchInteraction
    let owner: UUID
}
