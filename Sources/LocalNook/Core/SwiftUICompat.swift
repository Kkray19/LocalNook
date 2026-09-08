//
//  SwiftUICompat.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import SwiftUI

// MARK: - @LNState
//
// In the macOS 27 SDK, `State` is declared twice: as the familiar
// `@propertyWrapper struct State<Value>` *and* as an attached macro
// (`SwiftUICore.State`) implemented by the `SwiftUIMacros` compiler plugin.
// Overload resolution prefers the macro — but that plugin ships only with full
// Xcode, not with the Command Line Tools, so `@State` fails to compile here
// with "plugin for module 'SwiftUIMacros' not found".
//
// A typealias can only name the *type*, never the macro, so referring to the
// wrapper through `LNState` unambiguously selects the property-wrapper form.
// Behaviour is identical to `@State`; only the spelling differs.
//
// If LocalNook is ever built with full Xcode installed, plain `@State` would
// also work — this shim stays correct either way, so there is nothing to undo.

/// Drop-in replacement for `@State` that does not require the SwiftUI macro plugin.
typealias LNState<Value> = SwiftUI.State<Value>
