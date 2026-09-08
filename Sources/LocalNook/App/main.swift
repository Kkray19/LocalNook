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

// A plain AppKit entry point rather than SwiftUI's `App`: LocalNook owns its
// panels directly and must never create a regular window or main menu.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
