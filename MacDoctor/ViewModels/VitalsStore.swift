//
//  MacDoctor/ViewModels/VitalsStore.swift
//  Mac Doctor
//
//  Main-actor state holder shared between the MenuBarExtra label and the
//  popover. Sampling happens inside the services' actors; this type applies
//  snapshots, manages the 60-second histories, tracks alert thresholds
//  (including 30s sustained CPU), respects Low Impact Mode on battery, and
//  dispatches optional macOS notifications.
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class VitalsStore {
    private(set) var snapshot: SystemSnapshot = .empty
    private(set) var cpuHistory: [Double] = []
    private(set) var temperatureHistory: [Double] = []
    private(set) var networkHistory: [ThroughputPoint] = []
    private(set) var todayDownloadedBytes: UInt64 = 0
    private(set) var todayUploadedBytes: UInt64 = 0
    private(set) var lastUpdated: Date?
    private(set) var menuBarAlertTone: StatusTone = .neutral
    private(set) var activeAlertSummary: String?
    /// Pre-formatted compact menu bar string. Mutated ONLY when the rendered
    /// text actually changes so `MenuBarLabelView` avoids needless redraws.
    private(set) var menuBarDisplayText: String?

    private let sampler: any SystemSampling
    private let settings: SettingsStore
    private let notifier: any AlertNotifying

    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var highCPUSince: Date?
    @ObservationIgnored private var previousSampleDate: Date?
    @ObservationIgnored private var usageDayKey: String = ""
    @ObservationIgnored private var lastUsagePersistUptime: TimeInterval = 0
    @ObservationIgnored private var isPopoverVisible = false
    @ObservationIgnored private var isTemperaturesTabVisible = false
    @ObservationIgnored nonisolated(unsafe) private var terminateObserver: NSObjectProtocol?

    // Non-observed backing buffers updated while the popover is closed so the
    // hidden AppShellView SwiftUI graph suffers ZERO invalidations until opened.
    @ObservationIgnored private var bufferedSnapshot: SystemSnapshot = .empty
    @ObservationIgnored private var bufferedCPUHistory: [Double] = []
    @ObservationIgnored private var bufferedTempHistory: [Double] = []
    @ObservationIgnored private var bufferedNetworkHistory: [ThroughputPoint] = []
    @ObservationIgnored private var bufferedTodayDown: UInt64 = 0
    @ObservationIgnored private var bufferedTodayUp: UInt64 = 0

    private static let usageDayDefaultsKey = "dailyNetworkUsageDay"
    private static let usageDownDefaultsKey = "dailyNetworkDownBytes"
    private static let usageUpDefaultsKey = "dailyNetworkUpBytes"
    private static let usagePersistInterval: TimeInterval = 60

    init(
        sampler: any SystemSampling = SystemSampler(),
        settings: SettingsStore = SettingsStore(),
        notifier: any AlertNotifying = AlertNotificationService()
    ) {
        self.sampler = sampler
        self.settings = settings
        self.notifier = notifier
        loadDailyUsage()
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.persistDailyUsageNow()
            }
        }
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

    /// True when the Mac has a battery and is currently unplugged.
    var isOnBattery: Bool {
        let battery = isPopoverVisible ? snapshot.battery : bufferedSnapshot.battery
        guard let battery else { return false }
        return !battery.isPluggedIn
    }

    /// True when Low Impact Mode is actively slowing down polling on battery.
    var isLowImpactActive: Bool {
        settings.lowImpactModeEnabled && isOnBattery
    }

    var activePollingSeconds: Int {
        settings.effectivePollingSeconds(isOnBattery: isOnBattery)
    }

    var historyLimit: Int {
        let points = Int((60.0 / Double(max(activePollingSeconds, 1))).rounded()) + 1
        return min(max(points, 12), 61)
    }

    var health: SystemHealth {
        guard snapshot.hasReadings else { return .starting }

        if menuBarAlertTone == .critical {
            return .critical
        }

        let thermal = snapshot.thermal?.condition
        let pressure = snapshot.memory?.pressure
        let battery = snapshot.battery

        if thermal == .critical || pressure == .critical {
            return .critical
        }

        if let battery, !battery.isPluggedIn, battery.percentage <= 10 {
            return .critical
        }

        if menuBarAlertTone == .warning || thermal == .serious || pressure == .warning {
            return .elevated
        }

        if let battery, !battery.isPluggedIn, battery.percentage <= 20 {
            return .elevated
        }

        return .stable
    }

    /// Updates popover visibility so background (closed) mode can drop to
    /// minimal hardware polling with coalesced Efficiency-core wakeups, while
    /// opening the popover immediately wakes full live telemetry.
    func setPopoverVisible(_ visible: Bool) {
        guard isPopoverVisible != visible else { return }
        isPopoverVisible = visible
        if visible {
            flushBuffersToObservedState()
        }
        restartPollingLoop()
    }

    private func flushBuffersToObservedState() {
        if bufferedSnapshot.hasReadings {
            snapshot = bufferedSnapshot
            lastUpdated = bufferedSnapshot.capturedAt
        }
        cpuHistory = bufferedCPUHistory
        temperatureHistory = bufferedTempHistory
        networkHistory = bufferedNetworkHistory
        todayDownloadedBytes = bufferedTodayDown
        todayUploadedBytes = bufferedTodayUp
    }

    func setTemperaturesTabVisible(_ visible: Bool) {
        let changed = isTemperaturesTabVisible != visible
        isTemperaturesTabVisible = visible
        if changed && visible && isPopoverVisible {
            Task(priority: .utility) { [weak self] in
                await self?.refreshOnce()
            }
        }
    }

    /// Starts the shared background polling loop once. Safe to call from both
    /// `MenuBarLabelView` and `AppShellView`.
    func startIfNeeded() {
        guard pollingTask == nil else { return }
        restartPollingLoop()
    }

    func reschedulePolling() {
        guard pollingTask != nil else { return }
        restartPollingLoop()
    }

    private func restartPollingLoop() {
        pollingTask?.cancel()
        let priority: TaskPriority = isPopoverVisible ? .utility : .background
        pollingTask = Task(priority: priority) { [weak self] in
            await self?.run()
        }
    }

    func run() async {
        while !Task.isCancelled {
            await refreshOnce()

            let (sleepDuration, tolerance) = nextSleepSchedule()
            do {
                try await Task.sleep(for: sleepDuration, tolerance: tolerance)
            } catch {
                return
            }
        }
    }

    private func nextSleepSchedule() -> (Duration, Duration) {
        if isPopoverVisible {
            let secs = settings.effectivePollingSeconds(isOnBattery: isOnBattery)
            let tol = secs >= 5 ? Duration.milliseconds(600) : Duration.milliseconds(300)
            return (.seconds(secs), tol)
        }

        // Popover is closed.
        if settings.menuBarReadout == .none {
            // Icon-only watchdog: coalesce wakeups aggressively to minimize
            // CPU, package wakeups, and battery draw.
            let secs = isLowImpactActive ? 15 : 10
            return (.seconds(secs), .seconds(2))
        }

        // User enabled a live numeric menu bar readout — cap background
        // SwiftUI MenuBarExtra redraws to at most once every 3s (5s+ on battery)
        // with timer coalescing so macOS MenuBarExtraHost stays ultra-light.
        let baseSecs = settings.effectivePollingSeconds(isOnBattery: isOnBattery)
        let secs = max(baseSecs, isLowImpactActive ? 6 : 3)
        return (.seconds(secs), .milliseconds(750))
    }

    private func currentSamplingScope() -> SamplingScope {
        if isPopoverVisible {
            return .activeFull(preferFullTemperatures: isTemperaturesTabVisible)
        }
        let needsTemp = settings.menuBarReadout == .temperature || settings.notificationsEnabled
        let needsNet = settings.menuBarReadout == .network
        return .background(includeTemperature: needsTemp, includeNetwork: needsNet)
    }

    /// Samples once and applies the result.
    func refreshOnce() async {
        let scope = currentSamplingScope()
        let next = await sampler.sample(scope: scope)
        guard !Task.isCancelled else { return }
        apply(next)
    }

    private func apply(_ next: SystemSnapshot) {
        bufferedSnapshot = next

        let limit = historyLimit

        if let usage = next.cpu?.totalUsage {
            bufferedCPUHistory.append(min(max(usage, 0), 1))
            if bufferedCPUHistory.count > limit {
                bufferedCPUHistory.removeFirst(bufferedCPUHistory.count - limit)
            }
        }

        if let hottestCelsius = next.temperatures?.hottest?.celsius, hottestCelsius.isFinite {
            bufferedTempHistory.append(hottestCelsius)
            if bufferedTempHistory.count > limit {
                bufferedTempHistory.removeFirst(bufferedTempHistory.count - limit)
            }
        }

        if let down = next.network?.downloadBytesPerSecond,
           let up = next.network?.uploadBytesPerSecond {
            bufferedNetworkHistory.append(
                ThroughputPoint(
                    downloadBytesPerSecond: down,
                    uploadBytesPerSecond: up,
                    timestamp: next.capturedAt
                )
            )
            if bufferedNetworkHistory.count > limit {
                bufferedNetworkHistory.removeFirst(bufferedNetworkHistory.count - limit)
            }

            if let prevDate = previousSampleDate {
                let elapsed = min(max(next.capturedAt.timeIntervalSince(prevDate), 0), 30)
                accumulateDailyUsage(
                    downBytes: UInt64(max(0, down * elapsed)),
                    upBytes: UInt64(max(0, up * elapsed)),
                    at: next.capturedAt
                )
            }
        }

        previousSampleDate = next.capturedAt

        // Only mutate @Observable popover properties when the popover is open;
        // when closed, AppShellView stays 100% quiescent (zero SwiftUI redraws).
        if isPopoverVisible {
            snapshot = next
            lastUpdated = next.capturedAt
            cpuHistory = bufferedCPUHistory
            temperatureHistory = bufferedTempHistory
            networkHistory = bufferedNetworkHistory
            todayDownloadedBytes = bufferedTodayDown
            todayUploadedBytes = bufferedTodayUp
        }

        evaluateThresholds(for: next)
        refreshMenuBarDisplayText(for: next)
    }

    func refreshMenuBarDisplayText() {
        refreshMenuBarDisplayText(for: bufferedSnapshot.hasReadings ? bufferedSnapshot : snapshot)
    }

    private func refreshMenuBarDisplayText(for sample: SystemSnapshot) {
        let nextText: String?
        switch settings.menuBarReadout {
        case .none:
            nextText = nil
        case .cpu:
            if let usage = sample.cpu?.totalUsage {
                nextText = "\(Int((min(max(usage, 0), 1) * 100).rounded()))%"
            } else {
                nextText = "—"
            }
        case .temperature:
            let celsius = sample.temperatures?.hottestCPU ?? sample.temperatures?.hottest?.celsius
            nextText = settings.temperatureUnit.format(celsius, decimals: 0)
        case .network:
            if let down = sample.network?.downloadBytesPerSecond,
               let up = sample.network?.uploadBytesPerSecond {
                nextText = "↓\(Self.compactRate(down)) ↑\(Self.compactRate(up))"
            } else {
                nextText = "—"
            }
        }

        if menuBarDisplayText != nextText {
            menuBarDisplayText = nextText
        }
    }

    private static func compactRate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1_000 {
            return "\(Int(bytesPerSecond.rounded()))B"
        }
        let kb = bytesPerSecond / 1_000
        if kb < 1_000 {
            return "\(Int(kb.rounded()))K"
        }
        let mb = kb / 1_000
        if mb < 1_000 {
            return mb < 10 ? String(format: "%.1fM", mb) : "\(Int(mb.rounded()))M"
        }
        return String(format: "%.1fG", mb / 1_000)
    }

    // MARK: - Daily data usage & diagnostic report

    func diagnosticMarkdownReport() -> String {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let chip = snapshot.cpu?.brand ?? "Apple Silicon"
        let cpuText = MetricFormat.percent(snapshot.cpu?.totalUsage)
        let memText = snapshot.memory.map {
            "\(MetricFormat.memory($0.usedBytes)) / \(MetricFormat.memory($0.totalBytes)) (\($0.pressure.label))"
        } ?? "Unavailable"
        let diskText = snapshot.disk.flatMap { d -> String? in
            guard let free = d.freeBytes, let total = d.totalBytes else { return nil }
            return "\(MetricFormat.disk(free)) free of \(MetricFormat.disk(total))"
        } ?? "Unavailable"
        let batteryText = snapshot.battery.map { b in
            var parts = ["\(b.percentage)%"]
            if let w = MetricFormat.watts(b.powerWatts) { parts.append(w) }
            if let h = MetricFormat.health(b.health) { parts.append("health \(h)") }
            if let c = b.cycleCount { parts.append("\(c) cycles") }
            return parts.joined(separator: ", ")
        } ?? "No battery"
        let thermalText = snapshot.thermal?.condition.label ?? "Unavailable"
        let tempText = snapshot.temperatures?.hottest.map {
            "\(settings.temperatureUnit.format($0.celsius, decimals: 1)) (\($0.group.title))"
        } ?? "Unavailable"

        return """
        # Mac Doctor Snapshot
        - **System:** \(chip) · macOS \(osVersion)
        - **CPU:** \(cpuText)
        - **Memory:** \(memText)
        - **Disk:** \(diskText)
        - **Battery:** \(batteryText)
        - **Thermal State:** \(thermalText)
        - **Hottest Sensor:** \(tempText)
        - **Today's Network:** ↓ \(MetricFormat.disk(todayDownloadedBytes)) · ↑ \(MetricFormat.disk(todayUploadedBytes))
        """
    }

    private func loadDailyUsage() {
        let today = Self.dayStamp(for: .now)
        usageDayKey = today
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.usageDayDefaultsKey) == today {
            bufferedTodayDown = UInt64(max(0, defaults.double(forKey: Self.usageDownDefaultsKey)))
            bufferedTodayUp = UInt64(max(0, defaults.double(forKey: Self.usageUpDefaultsKey)))
        } else {
            bufferedTodayDown = 0
            bufferedTodayUp = 0
            defaults.set(today, forKey: Self.usageDayDefaultsKey)
            defaults.set(0.0, forKey: Self.usageDownDefaultsKey)
            defaults.set(0.0, forKey: Self.usageUpDefaultsKey)
        }
        todayDownloadedBytes = bufferedTodayDown
        todayUploadedBytes = bufferedTodayUp
    }

    private func accumulateDailyUsage(downBytes: UInt64, upBytes: UInt64, at date: Date) {
        let today = Self.dayStamp(for: date)
        var dayRolledOver = false
        if today != usageDayKey {
            usageDayKey = today
            bufferedTodayDown = 0
            bufferedTodayUp = 0
            dayRolledOver = true
        }
        bufferedTodayDown &+= downBytes
        bufferedTodayUp &+= upBytes

        let uptime = ProcessInfo.processInfo.systemUptime
        if dayRolledOver || (uptime - lastUsagePersistUptime) >= Self.usagePersistInterval {
            persistDailyUsageNow()
            lastUsagePersistUptime = uptime
        }
    }

    private func persistDailyUsageNow() {
        let defaults = UserDefaults.standard
        defaults.set(usageDayKey, forKey: Self.usageDayDefaultsKey)
        defaults.set(Double(bufferedTodayDown), forKey: Self.usageDownDefaultsKey)
        defaults.set(Double(bufferedTodayUp), forKey: Self.usageUpDefaultsKey)
    }

    private static func dayStamp(for date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    // MARK: - Threshold evaluation & notifications

    private func evaluateThresholds(for sample: SystemSnapshot) {
        let now = sample.capturedAt
        var severity: StatusTone = .neutral
        var reasons: [String] = []
        var pendingEvents: [AlertEvent] = []

        func elevate(_ candidate: StatusTone) {
            switch (severity, candidate) {
            case (_, .critical):
                severity = .critical
            case (.neutral, .warning), (.success, .warning):
                severity = .warning
            default:
                break
            }
        }

        // 1. CPU > threshold (default 85%) sustained for 30s+
        if let usage = sample.cpu?.totalUsage {
            let percent = usage * 100
            if percent >= settings.cpuAlertThresholdPercent {
                let started = highCPUSince ?? now
                highCPUSince = started
                let elapsed = now.timeIntervalSince(started)
                if elapsed >= AppSettingsKeys.cpuSustainedDurationSeconds {
                    let level: StatusTone = percent >= 95 ? .critical : .warning
                    elevate(level)
                    let pctInt = Int(percent.rounded())
                    reasons.append("CPU \(pctInt)% for \(Int(elapsed))s")
                    pendingEvents.append(AlertEvent(
                        kind: .highCPU,
                        severity: level,
                        title: "High CPU Usage",
                        body: "CPU has stayed at \(pctInt)% for over 30 seconds."
                    ))
                }
            } else {
                highCPUSince = nil
            }
        }

        // 2. Temperature above user threshold
        if let hottest = sample.temperatures?.hottest {
            let threshold = settings.temperatureAlertThresholdCelsius
            if hottest.celsius >= threshold {
                elevate(.critical)
                let formatted = settings.temperatureUnit.format(hottest.celsius, decimals: 0)
                reasons.append("\(hottest.group.title) \(formatted)")
                pendingEvents.append(AlertEvent(
                    kind: .highTemperature,
                    severity: .critical,
                    title: "High Temperature",
                    body: "\(hottest.group.title) reached \(formatted) (above your \(settings.temperatureUnit.format(threshold, decimals: 0)) limit)."
                ))
            } else if hottest.celsius >= threshold - 10 {
                elevate(.warning)
                let formatted = settings.temperatureUnit.format(hottest.celsius, decimals: 0)
                reasons.append("\(hottest.group.title) \(formatted)")
            }
        }

        // 3. Memory pressure warning / critical
        if settings.memoryPressureAlertEnabled, let pressure = sample.memory?.pressure {
            switch pressure {
            case .critical:
                elevate(.critical)
                reasons.append("Memory pressure critical")
                pendingEvents.append(AlertEvent(
                    kind: .memoryPressure,
                    severity: .critical,
                    title: "Critical Memory Pressure",
                    body: "macOS reports critical memory pressure. Consider quitting heavy apps."
                ))
            case .warning:
                elevate(.warning)
                reasons.append("Memory pressure high")
                pendingEvents.append(AlertEvent(
                    kind: .memoryPressure,
                    severity: .warning,
                    title: "High Memory Pressure",
                    body: "Memory pressure is elevated. Performance may slow down."
                ))
            case .normal, .unknown:
                break
            }
        }

        if menuBarAlertTone != severity {
            menuBarAlertTone = severity
        }
        let nextSummary = reasons.isEmpty ? nil : reasons.joined(separator: " · ")
        if activeAlertSummary != nextSummary {
            activeAlertSummary = nextSummary
        }

        if settings.notificationsEnabled, !pendingEvents.isEmpty {
            let notifier = self.notifier
            Task {
                for event in pendingEvents {
                    await notifier.send(event)
                }
            }
        }
    }
}
