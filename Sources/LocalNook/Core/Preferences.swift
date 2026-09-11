//
//  Preferences.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  A dependency-free replacement for the `Defaults` package used by the
//  upstream project. Everything lives in the standard user defaults suite so
//  the app stays fully local and has no first-run network or account needs.
//

import Combine
import Foundation
import SwiftUI

/// A value that can round-trip through `UserDefaults`.
///
/// Primitives are stored natively so the plist stays human-readable and
/// `defaults read` works; everything else is JSON-encoded.
protocol PrefValue {
    static func read(_ key: String, from store: UserDefaults) -> Self?
    func write(_ key: String, to store: UserDefaults)
}

extension PrefValue where Self: Codable {
    static func read(_ key: String, from store: UserDefaults) -> Self? {
        guard let data = store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func write(_ key: String, to store: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        store.set(data, forKey: key)
    }
}

/// Types `UserDefaults` stores natively.
protocol NativePrefValue: PrefValue {}

extension NativePrefValue {
    static func read(_ key: String, from store: UserDefaults) -> Self? {
        store.object(forKey: key) as? Self
    }

    func write(_ key: String, to store: UserDefaults) {
        store.set(self, forKey: key)
    }
}

extension Bool: NativePrefValue {}
extension Int: NativePrefValue {}
extension Double: NativePrefValue {}
extension String: NativePrefValue {}

extension Array: PrefValue where Element: Codable {}
extension Dictionary: PrefValue where Key: Codable, Value: Codable {}
extension Optional: PrefValue where Wrapped: Codable {}

/// `RawRepresentable` enums persist as their raw value.
extension PrefValue where Self: RawRepresentable, Self.RawValue: NativePrefValue {
    static func read(_ key: String, from store: UserDefaults) -> Self? {
        guard let raw = RawValue.read(key, from: store) else { return nil }
        return Self(rawValue: raw)
    }

    func write(_ key: String, to store: UserDefaults) {
        rawValue.write(key, to: store)
    }
}

/// Persists a property in `UserDefaults` and republishes the owning
/// `ObservableObject` whenever it changes.
///
/// Uses the enclosing-instance subscript so a plain `var` declaration gets both
/// persistence and SwiftUI change notification with no per-property boilerplate.
@propertyWrapper
final class Pref<Value: PrefValue> {
    let key: String
    let defaultValue: Value
    private var cached: Value?
    private let store: UserDefaults

    init(_ key: String, _ defaultValue: Value, store: UserDefaults = AppInfo.defaults) {
        self.key = key
        self.defaultValue = defaultValue
        self.store = store
    }

    /// Reads through the in-memory cache so hot paths (hover ticks, animation
    /// frames) never hit the defaults database.
    fileprivate var value: Value {
        get {
            if let cached { return cached }
            let resolved = Value.read(key, from: store) ?? defaultValue
            cached = resolved
            return resolved
        }
        set {
            cached = newValue
            newValue.write(key, to: store)
        }
    }

    fileprivate func invalidateCache() { cached = nil }

    @available(*, unavailable, message: "@Pref is only valid on ObservableObject classes")
    var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }

    static subscript<Enclosing: ObservableObject>(
        _enclosingInstance instance: Enclosing,
        wrapped _: ReferenceWritableKeyPath<Enclosing, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<Enclosing, Pref>
    ) -> Value where Enclosing.ObjectWillChangePublisher == ObservableObjectPublisher {
        get { instance[keyPath: storageKeyPath].value }
        set {
            instance.objectWillChange.send()
            instance[keyPath: storageKeyPath].value = newValue
        }
    }
}
