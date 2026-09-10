//
//  SystemMonitor.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Samples SystemTelemetry while something is watching, and not otherwise.
//
//  A system monitor that polls whether or not anyone is looking is the exact
//  thing that keeps a laptop awake, and this app has spent a lot of care not
//  being that. So sampling is reference-counted: the first view to appear
//  starts it, the last to vanish stops it, and a collapsed notch samples
//  nothing at all.
//
//  Battery health is fetched separately and rarely. It is the one slow read
//  here — a `system_profiler` call of about a second — and the answer changes
//  on the order of days, so it runs once per session and then every six hours.
//

import Combine
import Foundation

final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published private(set) var cpu: Double?
    @Published private(set) var gpu: Double?
    @Published private(set) var memory = MemoryStats()
    @Published private(set) var power = PowerStats()
    @Published private(set) var uptime: TimeInterval?
    /// Free and total bytes on the boot volume. Carried here so the System page
    /// keeps the storage figure the Stats widget used to show.
    @Published private(set) var storage: (free: Int64, total: Int64) = (0, 0)
    /// Recent processor load, oldest first, for the trend line.
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var gpuHistory: [Double] = []

    /// How many points the trend lines keep. At the sampling interval below
    /// this is about a minute of history, which is what a glance wants.
    static let historyLength = 40
    static let interval: TimeInterval = 1.5
    private static let healthInterval: TimeInterval = 6 * 3600

    private var timer: AnyCancellable?
    private var watchers = 0
    private var lastTicks: ProcessorTicks?
    private var healthReadAt: Date?

    private init() {}

    // MARK: Lifecycle

    /// Called by a view appearing. Balanced by `release()`.
    func retain() {
        watchers += 1
        guard watchers == 1 else { return }
        // One sample always, so a preview render composes a populated page
        // rather than a row of dashes. The *timer* is the part a harness must
        // not start: a suite that leaves a repeating sampler running is
        // measuring a machine it is also loading.
        sample()

        // Processor load is a difference, so the first sample can only seed the
        // baseline and the panel would read "—" until the first tick. A second
        // sample a fraction of a second later fills it in immediately.
        //
        // The renderer takes its screenshot the moment the view is built, so
        // there it has to be synchronous; everywhere else that would be a
        // sleep on the main thread, so it is scheduled instead.
        if AppInfo.isIsolatedRun {
            Thread.sleep(forTimeInterval: 0.12)
            sample()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.watchers > 0 else { return }
            self.sample()
        }
        timer = Timer.publish(every: Self.interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.sample() }
    }

    func release() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.cancel()
        timer = nil
        // The next reader starts a fresh baseline rather than differencing
        // against ticks from minutes ago, which would report the average since
        // then as though it were the load now.
        lastTicks = nil
    }

    var isSampling: Bool { timer != nil }

    // MARK: Sampling

    func sample() {
        if let ticks = ProcessorTicks.read() {
            if let lastTicks, let load = ticks.load(since: lastTicks) {
                cpu = load
                cpuHistory = Self.appending(load, to: cpuHistory)
            }
            lastTicks = ticks
        }
        if let load = GraphicsLoad.read() {
            gpu = load
            gpuHistory = Self.appending(load, to: gpuHistory)
        }
        if let stats = MemoryStats.read() { memory = stats }
        uptime = SystemUptime.seconds()
        if let values = try? URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        ) {
            storage = (Int64(values.volumeAvailableCapacityForImportantUsage ?? 0),
                       Int64(values.volumeTotalCapacity ?? 0))
        }

        var latest = PowerStats.read()
        latest.healthPercent = power.healthPercent
        power = latest
        refreshHealthIfStale()
    }

    static func appending(_ value: Double, to history: [Double]) -> [Double] {
        var next = history
        next.append(value)
        if next.count > historyLength { next.removeFirst(next.count - historyLength) }
        return next
    }

    private func refreshHealthIfStale() {
        if let healthReadAt, Date().timeIntervalSince(healthReadAt) < Self.healthInterval { return }
        healthReadAt = Date()
        Task { [weak self] in
            let output = await ProcessRunner.run(
                "/usr/sbin/system_profiler", ["SPPowerDataType"], timeout: .seconds(20)
            )
            guard let health = PowerStats.parseHealth(fromProfilerOutput: output.standardOutput)
            else { return }
            await MainActor.run { self?.power.healthPercent = health }
        }
    }
}
