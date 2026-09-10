//
//  SystemTelemetry.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  What the machine is doing: processor and graphics load, memory, uptime, and
//  where the watts are going.
//
//  ── Read from macOS, not from another app ──────────────────────────────────
//
//  This began as a request to mirror another utility's panels into the notch.
//  Reading that app's numbers turned out to be impossible — it computes them
//  live and writes none of them down — and also unnecessary, because they are
//  the machine's own figures and macOS hands them to anyone who asks. Reading
//  them directly means no dependency on another app's undocumented storage,
//  nothing to break when that app updates, and no network.
//
//  ── Public interfaces only, and the one deliberate omission ────────────────
//
//  Nothing here needs root and nothing uses a private API:
//
//    * Processor load from `host_processor_info`, differenced between reads.
//      The counters are cumulative ticks since boot, so one sample says what
//      the machine has done since it started, not what it is doing now.
//    * Memory from `host_statistics64`; swap from `sysctl vm.swapusage`.
//    * Uptime from `kern.boottime`.
//
//  The omission is temperature. CPU, GPU and battery temperatures sit behind
//  `IOHIDEventSystemClient`, which is private. It works today and is exactly
//  the kind of thing that stops working on an OS update, so the panel says
//  temperatures are unavailable rather than showing a figure that could
//  quietly go wrong.
//

import Darwin
import Foundation

// MARK: - Processor

/// Cumulative processor ticks. Only the difference between two of these means
/// anything — see the note above.
nonisolated struct ProcessorTicks: Equatable, Sendable {
    var used: UInt64 = 0
    var total: UInt64 = 0

    /// Load between two samples, or nil when the counters have not moved —
    /// which happens when two reads land inside the same tick.
    func load(since earlier: ProcessorTicks) -> Double? {
        let elapsed = total >= earlier.total ? total - earlier.total : 0
        guard elapsed > 0 else { return nil }
        let busy = used >= earlier.used ? used - earlier.used : 0
        return min(1, max(0, Double(busy) / Double(elapsed)))
    }

    static func read() -> ProcessorTicks? {
        var count = mach_msg_type_number_t(0)
        var cpus: natural_t = 0
        var info: processor_info_array_t?
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpus, &info, &count) == KERN_SUCCESS,
              let info
        else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        var ticks = ProcessorTicks()
        for cpu in 0..<Int(cpus) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            ticks.used += user + system + nice
            ticks.total += user + system + nice + idle
        }
        return ticks
    }
}

// MARK: - Memory

nonisolated struct MemoryStats: Equatable, Sendable {
    /// Bytes throughout.
    var used: UInt64 = 0
    var total: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0

    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    /// How hard the machine is working to keep memory available.
    ///
    /// A classification, not a reading, and named so. macOS publishes a real
    /// pressure level through `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`, but only
    /// for the calling process and only as a change notification, so it cannot
    /// describe the machine. This classifies the figures already on screen.
    nonisolated enum Pressure: String, Equatable, Sendable {
        case normal, caution, urgent

        var label: String {
            switch self {
            case .normal: "Normal"
            case .caution: "Caution"
            case .urgent: "Urgent"
            }
        }
    }

    /// Swap in use is the strongest signal available without a private call:
    /// a machine only swaps once compression has stopped being enough.
    var pressure: Pressure {
        let swapGB = Double(swapUsed) / 1_073_741_824
        if fraction >= 0.90 || swapGB >= 4 { return .urgent }
        if fraction >= 0.75 || swapGB >= 1 { return .caution }
        return .normal
    }

    static func read() -> MemoryStats? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        let page = UInt64(pageSize)

        var memory = MemoryStats()
        memory.total = ProcessInfo.processInfo.physicalMemory
        memory.compressed = UInt64(stats.compressor_page_count) * page
        memory.cached = UInt64(stats.external_page_count) * page
        // What macOS calls "memory used": everything not free and not
        // reclaimable file cache.
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        memory.used = ((internalPages >= purgeable ? internalPages - purgeable : 0)
                        + UInt64(stats.wire_count)
                        + UInt64(stats.compressor_page_count)) * page
        memory.swapUsed = swapInUse() ?? 0
        return memory
    }

    /// Bytes of swap in use.
    static func swapInUse() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
    }

    /// "6.26 GB". Written out rather than taken from a formatter so the suite
    /// can assert it and so it does not shift with the locale.
    static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
    }
}

// MARK: - Uptime

nonisolated enum SystemUptime {
    /// Seconds since boot, from the kernel's own boot timestamp.
    static func seconds(now: Date = Date()) -> TimeInterval? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0
        else { return nil }
        let elapsed = now.timeIntervalSince1970 - TimeInterval(boot.tv_sec)
        return elapsed > 0 ? elapsed : nil
    }

    /// "5d 16h", "16h 4m", "4m".
    static func label(seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
