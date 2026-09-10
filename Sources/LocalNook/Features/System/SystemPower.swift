//
//  SystemPower.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Graphics load, and where the watts are going.
//
//  ── The watts are arithmetic, not a sensor ─────────────────────────────────
//
//  There is no public reading for "how much power is this Mac drawing". There
//  are two readings either side of it, and the machine's draw is what falls
//  out between them:
//
//      adapter in  = adapter voltage x adapter current
//      battery in  = battery voltage x battery current   (negative when discharging)
//      system draw = adapter in - battery in
//
//  Checked against a utility showing the same three figures on this Mac at the
//  same moment: adapter 20V x 2.24A = 44.8W against its 43W, battery
//  11.751V x 2.436A = 28.6W against its 28W, and 44.8 - 28.6 = 16.2W against
//  its 16W. The residual is real — a charger's output is not perfectly steady
//  and the two readings are not taken at the same instant — so this is
//  reported to the watt and never to a decimal place it has not earned.
//
//  On battery, adapter input is zero and the battery current is negative, so
//  the same subtraction gives the discharge rate as the system draw.
//
//  Battery *health* deliberately does not come from IOKit's capacity figures.
//  `NominalChargeCapacity / DesignCapacity` gives 84% on this Mac while both
//  macOS Settings and every utility on it say 90%: Apple's published figure is
//  computed differently. Disagreeing with the number the user can see
//  elsewhere would make this panel look broken, so health is read from
//  `system_profiler`, which is the same source, and cached because it is slow
//  and changes on the order of days.
//

import Foundation
import IOKit

// MARK: - Graphics

nonisolated enum GraphicsLoad {
    /// Utilisation 0…1, from the IORegistry's accelerator entry.
    ///
    /// Public registry data, no root. Absent rather than zero when the key is
    /// missing: a Mac that does not publish it is not a Mac at 0% load.
    static func read() -> Double? {
        let matching = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                service, &properties, kCFAllocatorDefault, 0
            ) == KERN_SUCCESS, let dictionary = properties?.takeRetainedValue() as? [String: Any]
            else { continue }
            guard let statistics = dictionary["PerformanceStatistics"] as? [String: Any],
                  let utilisation = statistics["Device Utilization %"] as? Int
            else { continue }
            best = max(best ?? 0, min(1, max(0, Double(utilisation) / 100)))
        }
        return best
    }
}

// MARK: - Power

nonisolated struct PowerStats: Equatable, Sendable {
    /// Watts. Absent where the machine does not report the inputs.
    var adapterWatts: Double?
    var adapterMaxWatts: Double?
    /// Positive while charging, negative while discharging.
    var batteryWatts: Double?
    var systemWatts: Double?
    var charge: Int?
    var cycleCount: Int?
    var isCharging = false
    var isPluggedIn = false
    /// Percent of original capacity, as macOS itself reports it.
    var healthPercent: Int?

    /// Watts to the nearest watt. See the header: the arithmetic does not earn
    /// a decimal place.
    static func watts(_ value: Double?) -> String? {
        guard let value, value.isFinite else { return nil }
        return "\(Int(value.rounded())) W"
    }

    /// The subtraction the whole panel rests on.
    static func systemDraw(adapter: Double?, battery: Double?) -> Double? {
        guard adapter != nil || battery != nil else { return nil }
        let draw = (adapter ?? 0) - (battery ?? 0)
        // A negative system draw is not physical; it means the two readings
        // were taken far enough apart to disagree. Absent beats impossible.
        return draw >= 0 ? draw : nil
    }

    static func read() -> PowerStats {
        var stats = PowerStats()
        guard let battery = batteryProperties() else { return stats }

        stats.charge = battery["CurrentCapacity"] as? Int
        stats.cycleCount = battery["CycleCount"] as? Int
        stats.isCharging = battery["IsCharging"] as? Bool ?? false
        stats.isPluggedIn = battery["ExternalConnected"] as? Bool ?? false

        // Millivolts and milliamps.
        if let millivolts = battery["Voltage"] as? Int,
           let milliamps = battery["InstantAmperage"] as? Int {
            stats.batteryWatts = Double(millivolts) * Double(milliamps) / 1_000_000
        }
        if let adapter = battery["AdapterDetails"] as? [String: Any] {
            if let millivolts = adapter["AdapterVoltage"] as? Int,
               let milliamps = adapter["Current"] as? Int {
                stats.adapterWatts = Double(millivolts) * Double(milliamps) / 1_000_000
            }
            if let watts = adapter["Watts"] as? Int { stats.adapterMaxWatts = Double(watts) }
            else { stats.adapterMaxWatts = stats.adapterWatts.map { ($0 / 5).rounded() * 5 } }
        }
        stats.systemWatts = systemDraw(adapter: stats.adapterWatts, battery: stats.batteryWatts)
        return stats
    }

    private static func batteryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service, &properties, kCFAllocatorDefault, 0
        ) == KERN_SUCCESS else { return nil }
        return properties?.takeRetainedValue() as? [String: Any]
    }

    /// "Maximum Capacity" as macOS reports it, parsed from `system_profiler`.
    ///
    /// The only slow call in this file, and the reason it is separated: it
    /// takes about a second, and the answer changes on the order of days.
    static func parseHealth(fromProfilerOutput text: String) -> Int? {
        for line in text.split(separator: "\n") {
            guard line.contains("Maximum Capacity") else { continue }
            let digits = line.filter(\.isNumber)
            guard !digits.isEmpty, let value = Int(digits), (1...100).contains(value)
            else { continue }
            return value
        }
        return nil
    }
}
