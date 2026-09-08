//
//  StatsWidgetView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import Combine
import Foundation
import SwiftUI

struct StatsWidgetView: View {
    @ObservedObject private var battery = BatteryMonitor.shared
    @LNState private var disk: (free: Int64, total: Int64) = (0, 0)
    @LNState private var memory: (used: Double, total: Double) = (0, 0)

    /// A slow tick — these numbers do not need to be live to the second.
    private let ticker = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            StatCard(
                title: "Battery",
                value: battery.state.isPresent ? "\(battery.state.percentage)%" : "—",
                detail: batteryDetail,
                symbol: battery.state.symbol,
                tint: battery.state.tint,
                fraction: Double(battery.state.percentage) / 100
            )
            StatCard(
                title: "Memory",
                value: memory.total > 0 ? "\(Int(memory.used / memory.total * 100))%" : "—",
                detail: memory.total > 0
                    ? "\(format(bytes: Int64(memory.used))) of \(format(bytes: Int64(memory.total)))"
                    : "",
                symbol: "memorychip",
                tint: .cyan,
                fraction: memory.total > 0 ? memory.used / memory.total : 0
            )
            StatCard(
                title: "Storage",
                value: disk.total > 0 ? "\(Int(Double(disk.total - disk.free) / Double(disk.total) * 100))%" : "—",
                detail: disk.total > 0 ? "\(format(bytes: disk.free)) free" : "",
                symbol: "internaldrive",
                tint: .purple,
                fraction: disk.total > 0 ? Double(disk.total - disk.free) / Double(disk.total) : 0
            )
        }
        .onAppear(perform: refresh)
        .onReceive(ticker) { _ in refresh() }
    }

    private var batteryDetail: String {
        let state = battery.state
        guard state.isPresent else { return "No battery" }
        if state.isCharging { return state.timeLabel.map { "\($0) to full" } ?? "Charging" }
        if state.isPluggedIn { return "Plugged in" }
        return state.timeLabel.map { "\($0) left" } ?? "On battery"
    }

    private func refresh() {
        battery.refresh()

        if let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        ) {
            disk = (
                Int64(values.volumeAvailableCapacityForImportantUsage ?? 0),
                Int64(values.volumeTotalCapacity ?? 0)
            )
        }

        memory = Self.memoryUsage()
    }

    private func format(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Physical memory in use, from the Mach VM statistics.
    private static func memoryUsage() -> (used: Double, total: Double) {
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total) }

        // `vm_kernel_page_size` is a mutable global and not concurrency-safe;
        // ask the kernel instead.
        var rawPageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &rawPageSize)
        let pageSize = Double(rawPageSize)
        // "Used" here mirrors Activity Monitor's memory-pressure view: active,
        // wired and compressed pages, excluding purgeable cache.
        let used = (Double(stats.active_count)
            + Double(stats.wire_count)
            + Double(stats.compressor_page_count)) * pageSize
        return (used, total)
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(title).font(.system(size: 9, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white.opacity(0.5))

            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(tint.opacity(0.85))
                        .frame(width: max(2, geometry.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 3)

            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.06)))
    }
}
