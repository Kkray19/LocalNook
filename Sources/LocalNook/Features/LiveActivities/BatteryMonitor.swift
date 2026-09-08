//
//  BatteryMonitor.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Battery state via the public IOKit power-source API. The run-loop source
//  means macOS tells us when something changes — there is no polling timer.
//

import Combine
import Foundation
import IOKit.ps
import SwiftUI

struct BatteryState: Equatable {
    var percentage: Int
    var isCharging: Bool
    var isPluggedIn: Bool
    var isPresent: Bool
    /// Minutes remaining, when the system is confident enough to report it.
    var minutesRemaining: Int?

    static let unknown = BatteryState(
        percentage: 0, isCharging: false, isPluggedIn: false,
        isPresent: false, minutesRemaining: nil
    )

    var isFull: Bool { percentage >= 100 }

    var symbol: String {
        guard isPresent else { return "bolt.slash" }
        if isCharging { return "battery.100percent.bolt" }
        return switch percentage {
        case ..<10: "battery.0percent"
        case ..<35: "battery.25percent"
        case ..<60: "battery.50percent"
        case ..<85: "battery.75percent"
        default: "battery.100percent"
        }
    }

    var tint: Color {
        if isCharging { return .green }
        return switch percentage {
        case ..<10: .red
        case ..<20: .orange
        default: .white
        }
    }

    var timeLabel: String? {
        guard let minutesRemaining, minutesRemaining > 0 else { return nil }
        let hours = minutesRemaining / 60
        let minutes = minutesRemaining % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()

    @Published private(set) var state: BatteryState = .unknown

    private var runLoopSource: CFRunLoopSource?

    private init() {
        refresh()
        installNotification()
    }

    // `isolated deinit` so teardown can touch main-actor state. In practice
    // this is a process-lifetime singleton and never runs, but leaving the
    // run-loop source installed on a dealloc would be a dangling callback.
    isolated deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
    }

    /// macOS calls us back on change, so nothing here runs while idle.
    private func installNotification() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { monitor.refresh() }
            }
        }, context)?.takeRetainedValue() else { return }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }

    func refresh() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            state = .unknown
            return
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }

            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let powerState = description[kIOPSPowerSourceStateKey] as? String
            let plugged = powerState == kIOPSACPowerValue

            // -1 means "still calculating"; showing that would be noise.
            let rawMinutes = description[kIOPSTimeToEmptyKey] as? Int ?? -1
            let chargeMinutes = description[kIOPSTimeToFullChargeKey] as? Int ?? -1
            let minutes = charging ? chargeMinutes : rawMinutes

            let percentage = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : 0

            let updated = BatteryState(
                percentage: min(100, max(0, percentage)),
                isCharging: charging,
                isPluggedIn: plugged,
                isPresent: true,
                minutesRemaining: minutes > 0 ? minutes : nil
            )

            if updated != state {
                let previous = state
                state = updated
                announceChanges(from: previous, to: updated)
            }
            return
        }

        // Desktop Mac, or no internal battery.
        if state.isPresent { state = .unknown }
    }

    /// Posts the events the live-activity layer turns into notch banners.
    private func announceChanges(from previous: BatteryState, to current: BatteryState) {
        guard previous.isPresent else { return }
        let center = NotificationCenter.default
        if previous.isPluggedIn != current.isPluggedIn {
            center.post(
                name: current.isPluggedIn ? .powerConnected : .powerDisconnected,
                object: current
            )
        }
        if !previous.isFull, current.isFull, current.isPluggedIn {
            center.post(name: .batteryFull, object: current)
        }
        if previous.percentage > 20, current.percentage <= 20, !current.isPluggedIn {
            center.post(name: .batteryLow, object: current)
        }
    }
}

extension Notification.Name {
    static let powerConnected = Notification.Name("LocalNook.powerConnected")
    static let powerDisconnected = Notification.Name("LocalNook.powerDisconnected")
    static let batteryFull = Notification.Name("LocalNook.batteryFull")
    static let batteryLow = Notification.Name("LocalNook.batteryLow")
}
