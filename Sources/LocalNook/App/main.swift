//
//  main.swift
//  LocalNook — a local-first macOS notch utility.
//
//  Copyright (C) 2026 Krish Kowli
//
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
//  more details. You should have received a copy of the GNU General Public
//  License along with this program. If not, see <https://www.gnu.org/licenses/>.
//
//  Portions derived from boring.notch (c) The Boring Team, GPL-3.0-or-later.
//

import AppKit
import Foundation

if CommandLine.arguments.contains("--version") {
    print("LocalNook \(AppInfo.version)\nCommit: \(AppInfo.commit)\nBuilt: \(AppInfo.builtAt)")
    exit(0)
}

// Development aid: render the notch UI offscreen to PNGs and exit.
// See PreviewRenderer.swift. Never reached in normal use.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--render-preview") {
    let path = CommandLine.arguments.count > flagIndex + 1
        ? CommandLine.arguments[flagIndex + 1]
        : FileManager.default.currentDirectoryPath
    PreviewRenderer.run(outputDirectory: URL(fileURLWithPath: path))
}

// Dumps the transition log of a *running* LocalNook is not possible from a
// second process; this prints the log of this process, which is useful after
// --self-test to see what moved the notch and why.
if CommandLine.arguments.contains("--transitions") {
    print(NotchTransitionLog.report)
    exit(0)
}

// Built-in test harness. See SelfTest.swift.
// Development aid: ask every media provider once and print what it said.
//
// Runs as the installed bundle, so it sees the same Automation consent the app
// does — which is the only way to tell "the browser said nothing" apart from
// "macOS refused to let us ask". Prints source names and playback state only,
// never a tab title, so it cannot leak what someone is watching into a log.
if CommandLine.arguments.contains("--media-probe") {
    MediaProbe.run()
}

// Development aid: what the session reader gets out of the real transcripts.
// Numbers and flags only — never a chat name, a step or a folder. See
// SessionsProbe.
if CommandLine.arguments.contains("--sessions-probe") {
    SessionsProbe.run()
}

if CommandLine.arguments.contains("--self-test") {
    SelfTest.run()
}

// A plain AppKit entry point rather than SwiftUI's `App`: LocalNook owns its
// panels directly and must never create a regular window or main menu.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
