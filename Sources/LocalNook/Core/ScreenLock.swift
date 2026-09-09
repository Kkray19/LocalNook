//
//  ScreenLock.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Whether the login window is covering the screen.
//
//  Two unrelated parts of the app need this and neither should own it: the
//  hover probe, which reports a locked screen as an unmet precondition rather
//  than a missing platform event, and the session reader, which must not put
//  content-derived labels on a locked screen and should not be scanning
//  transcripts for a display nobody can see.
//

import CoreGraphics
import Foundation

nonisolated enum ScreenLock {
    /// True while the login window is in front of everything.
    ///
    /// Read live rather than cached: the distributed notifications that report
    /// locking are observed elsewhere for UI purposes, but a decision about
    /// whether to *read a file* should ask the system at the moment it matters,
    /// not trust a flag that may have been missed.
    static var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (session["CGSSessionScreenIsLocked"] as? Int) == 1
    }
}
