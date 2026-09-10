//
//  SystemPageView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  The System page: what the machine is doing, at the width to say it.
//
//  Three regions that give way in a fixed order as the panel narrows, the same
//  way the AI Sessions page works — see SystemPageLayout. Load is the one that
//  survives every width, because a machine's load is the thing you opened this
//  to see; power and memory are richer but each is a section rather than the
//  point.
//
//  Every figure is the machine's own, read through public interfaces. The
//  temperatures another utility shows are deliberately absent, and the panel
//  says so rather than leaving a gap that looks like a bug — see
//  SystemTelemetry for why.
//

import SwiftUI

/// Which regions fit at a given panel width.
nonisolated struct SystemPageLayout: Equatable {
    var showsMemory: Bool
    var showsPower: Bool

    static let loadWidth: CGFloat = 210
    static let memoryWidth: CGFloat = 190
    static let powerWidth: CGFloat = 190
    static let railGap: CGFloat = 12

    static func plan(width: CGFloat) -> SystemPageLayout {
        let memoryCost = memoryWidth + railGap * 2 + 1
        let powerCost = powerWidth + railGap * 2 + 1
        if width >= loadWidth + memoryCost + powerCost {
            return SystemPageLayout(showsMemory: true, showsPower: true)
        }
        // Power goes before memory: memory's headline is already in the load
        // column's neighbours, whereas power has nowhere else to appear.
        if width >= loadWidth + powerCost {
            return SystemPageLayout(showsMemory: false, showsPower: true)
        }
        return SystemPageLayout(showsMemory: false, showsPower: false)
    }
}

struct SystemPageView: View {
    @ObservedObject private var monitor = SystemMonitor.shared

    var body: some View {
        GeometryReader { geometry in
            let layout = SystemPageLayout.plan(width: geometry.size.width)
            HStack(spacing: 0) {
                load
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                if layout.showsMemory {
                    SectionDivider().padding(.horizontal, SystemPageLayout.railGap)
                    memory.frame(width: SystemPageLayout.memoryWidth)
                }
                if layout.showsPower {
                    SectionDivider().padding(.horizontal, SystemPageLayout.railGap)
                    power.frame(width: SystemPageLayout.powerWidth)
                }
            }
        }
        // Reference counted: sampling runs only while this is on screen.
        .onAppear { monitor.retain() }
        .onDisappear { monitor.release() }
    }

    // MARK: Load

    private var load: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(WidgetKind.stats.label)
                    .font(Theme.sectionTitle)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize()
                Spacer(minLength: 4)
                if let uptime = monitor.uptime {
                    Label(SystemUptime.label(seconds: uptime), systemImage: "clock")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.quaternaryText)
                        .labelStyle(.titleAndIcon)
                        .help("Since the kernel's own boot timestamp")
                }
            }

            LoadRow(name: "CPU", value: monitor.cpu, history: monitor.cpuHistory,
                    tint: Theme.accent)
            LoadRow(name: "GPU", value: monitor.gpu, history: monitor.gpuHistory,
                    tint: Theme.positive)

            // Said plainly rather than left as an empty space someone has to
            // interpret. See SystemTelemetry.
            Label("Temperatures need a private API — not read",
                  systemImage: "thermometer.medium.slash")
                .font(.system(size: 8.5))
                .foregroundStyle(Theme.quaternaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help("CPU, GPU and battery temperatures are only available "
                      + "through IOHIDEventSystemClient, which is private and "
                      + "can stop working on any macOS update. LocalNook shows "
                      + "what it can read through public interfaces.")

            Spacer(minLength: 0)
        }
    }

    // MARK: Memory

    private var memory: some View {
        let stats = monitor.memory
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text("Memory")
                    .font(Theme.sectionTitle)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.tertiaryText)
                Spacer(minLength: 2)
                PressureChip(pressure: stats.pressure)
            }

            HStack(spacing: 4) {
                Text(MemoryStats.gigabytes(stats.used))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.primaryText)
                Text("/ \(MemoryStats.gigabytes(stats.total))")
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.tertiaryText)
            }

            Meter(fraction: stats.fraction, tint: tint(for: stats.pressure))

            DetailRow(name: "Compressed", value: MemoryStats.gigabytes(stats.compressed))
            DetailRow(name: "Cached files", value: MemoryStats.gigabytes(stats.cached))
            DetailRow(name: "Swap used", value: MemoryStats.gigabytes(stats.swapUsed))
            // Kept from the Stats widget this page replaces, so opening it
            // never costs you a figure you used to have.
            if monitor.storage.total > 0 {
                DetailRow(name: "Disk free",
                          value: MemoryStats.gigabytes(UInt64(max(0, monitor.storage.free))))
            }
            Spacer(minLength: 0)
        }
    }

    private func tint(for pressure: MemoryStats.Pressure) -> Color {
        switch pressure {
        case .normal: Theme.positive
        case .caution: Theme.warning
        case .urgent: Theme.weekend
        }
    }

    // MARK: Power

    private var power: some View {
        let stats = monitor.power
        return VStack(alignment: .leading, spacing: 4) {
            Text("Power")
                .font(Theme.sectionTitle)
                .textCase(.uppercase)
                .foregroundStyle(Theme.tertiaryText)
                .help("System draw is the adapter's input minus what is going "
                      + "into the battery. There is no public sensor for it.")

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(PowerStats.watts(stats.systemWatts) ?? "—")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.primaryText)
                Text("system")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiaryText)
            }

            if stats.isPluggedIn {
                DetailRow(name: "Adapter",
                          value: PowerStats.watts(stats.adapterWatts) ?? "—",
                          note: PowerStats.watts(stats.adapterMaxWatts).map { "\($0) max" })
            }
            DetailRow(name: stats.isCharging ? "Charging" : "Battery",
                      value: PowerStats.watts(stats.batteryWatts.map(abs)) ?? "—",
                      note: stats.charge.map { "\($0)%" })
            DetailRow(name: "Health",
                      value: stats.healthPercent.map { "\($0)%" } ?? "…",
                      note: stats.cycleCount.map { "\($0) cycles" })
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Pieces

/// One load line: a bar, a percentage, and where it has been.
private struct LoadRow: View {
    let name: String
    let value: Double?
    let history: [Double]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 28, alignment: .leading)
                Meter(fraction: value ?? 0, tint: tint)
                Text(value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 34, alignment: .trailing)
            }
            Sparkline(values: history, tint: tint)
                .frame(height: 16)
        }
    }
}

private struct Meter: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.primaryText.opacity(0.12))
                Capsule().fill(tint)
                    .frame(width: max(2, geometry.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
    }
}

/// Where a figure has been, for as long as this page has been open.
private struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            if values.count > 1 {
                Path { path in
                    let step = geometry.size.width / CGFloat(SystemMonitor.historyLength - 1)
                    // Right-aligned, so the newest sample is always at the edge
                    // and a half-filled history grows into the space rather
                    // than stretching to fill it.
                    let offset = CGFloat(SystemMonitor.historyLength - values.count) * step
                    for (index, value) in values.enumerated() {
                        let x = offset + CGFloat(index) * step
                        let y = geometry.size.height * (1 - CGFloat(min(1, max(0, value))))
                        let point = CGPoint(x: x, y: y)
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(tint.opacity(0.85), style: StrokeStyle(lineWidth: 1.2,
                                                               lineCap: .round,
                                                               lineJoin: .round))
            }
        }
    }
}

private struct DetailRow: View {
    let name: String
    let value: String
    var note: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.tertiaryText)
            Spacer(minLength: 4)
            if let note {
                Text(note)
                    .font(.system(size: 8.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.quaternaryText)
            }
            Text(value)
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

private struct PressureChip: View {
    let pressure: MemoryStats.Pressure

    private var tint: Color {
        switch pressure {
        case .normal: Theme.positive
        case .caution: Theme.warning
        case .urgent: Theme.weekend
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(pressure.label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(Theme.surface))
        .help("Classified from the figures shown here, not a reading from macOS")
    }
}
