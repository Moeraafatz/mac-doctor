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

    private let sampler: any SystemSampling
    private let settings: SettingsStore
    private let notifier: any AlertNotifying

    private var pollingTask: Task<Void, Never>?
    private var highCPUSince: Date?
    private var previousSampleDate: Date?
    private var usageDayKey: String = ""

    private static let usageDayDefaultsKey = "dailyNetworkUsageDay"
    private static let usageDownDefaultsKey = "dailyNetworkDownBytes"
    private static let usageUpDefaultsKey = "dailyNetworkUpBytes"

    init(
        sampler: any SystemSampling = SystemSampler(),
        settings: SettingsStore = SettingsStore(),
        notifier: any AlertNotifying = AlertNotificationService()
    ) {
        self.sampler = sampler
        self.settings = settings
        self.notifier = notifier
        loadDailyUsage()
    }

    /// True when the Mac has a battery and is currently unplugged.
    var isOnBattery: Bool {
        guard let battery = snapshot.battery else { return false }
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

    /// Starts the shared background polling loop once. Safe to call from both
    /// `MenuBarLabelView` and `AppShellView`.
    func startIfNeeded() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            await self?.run()
        }
    }

    func run() async {
        while !Task.isCancelled {
            await refreshOnce()

            let sleepDuration = settings.effectivePollingDuration(isOnBattery: isOnBattery)
            do {
                try await Task.sleep(for: sleepDuration)
            } catch {
                return
            }
        }
    }

    /// Samples once and applies the result.
    func refreshOnce() async {
        let next = await sampler.sample()
        guard !Task.isCancelled else { return }
        apply(next)
    }

    private func apply(_ next: SystemSnapshot) {
        snapshot = next
        lastUpdated = next.capturedAt

        let limit = historyLimit

        if let usage = next.cpu?.totalUsage {
            cpuHistory.append(min(max(usage, 0), 1))
            if cpuHistory.count > limit {
                cpuHistory.removeFirst(cpuHistory.count - limit)
            }
        }

        if let hottestCelsius = next.temperatures?.hottest?.celsius, hottestCelsius.isFinite {
            temperatureHistory.append(hottestCelsius)
            if temperatureHistory.count > limit {
                temperatureHistory.removeFirst(temperatureHistory.count - limit)
            }
        }

        if let down = next.network?.downloadBytesPerSecond,
           let up = next.network?.uploadBytesPerSecond {
            networkHistory.append(
                ThroughputPoint(
                    downloadBytesPerSecond: down,
                    uploadBytesPerSecond: up,
                    timestamp: next.capturedAt
                )
            )
            if networkHistory.count > limit {
                networkHistory.removeFirst(networkHistory.count - limit)
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
        evaluateThresholds(for: next)
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
            todayDownloadedBytes = UInt64(max(0, defaults.double(forKey: Self.usageDownDefaultsKey)))
            todayUploadedBytes = UInt64(max(0, defaults.double(forKey: Self.usageUpDefaultsKey)))
        } else {
            todayDownloadedBytes = 0
            todayUploadedBytes = 0
            defaults.set(today, forKey: Self.usageDayDefaultsKey)
            defaults.set(0.0, forKey: Self.usageDownDefaultsKey)
            defaults.set(0.0, forKey: Self.usageUpDefaultsKey)
        }
    }

    private func accumulateDailyUsage(downBytes: UInt64, upBytes: UInt64, at date: Date) {
        let today = Self.dayStamp(for: date)
        if today != usageDayKey {
            usageDayKey = today
            todayDownloadedBytes = 0
            todayUploadedBytes = 0
        }
        todayDownloadedBytes &+= downBytes
        todayUploadedBytes &+= upBytes

        let defaults = UserDefaults.standard
        defaults.set(today, forKey: Self.usageDayDefaultsKey)
        defaults.set(Double(todayDownloadedBytes), forKey: Self.usageDownDefaultsKey)
        defaults.set(Double(todayUploadedBytes), forKey: Self.usageUpDefaultsKey)
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

        menuBarAlertTone = severity
        activeAlertSummary = reasons.isEmpty ? nil : reasons.joined(separator: " · ")

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
