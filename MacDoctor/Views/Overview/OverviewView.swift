//
//  MacDoctor/Views/Overview/OverviewView.swift
//  Mac Doctor
//
//  The live vitals panel: one Black Liquid Glass CPU hero surface, followed by
//  six clean obsidian instrument tiles with inline Claude-orange utilization
//  bars where applicable.
//

import SwiftUI

struct OverviewView: View {
    let snapshot: SystemSnapshot
    let history: [Double]
    var onInspectPID: ((pid_t) -> Void)? = nil
    var onOpenCleaner: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            CPUPanel(sample: snapshot.cpu, history: history)
                .frame(height: 122)

            HStack(spacing: 9) {
                memoryTile
                gpuTile
            }

            HStack(spacing: 9) {
                diskTile
                networkTile
            }

            HStack(spacing: 9) {
                batteryTile
                thermalTile
            }

            if let diskAlertText {
                actionStrip(
                    icon: "sparkles",
                    text: diskAlertText,
                    tone: diskTone(snapshot.disk),
                    tooltip: "Open Safe Storage Cleaner to free up caches and Trash",
                    action: { onOpenCleaner?() }
                )
            } else if !snapshot.sleepBlockers.isEmpty {
                sleepBlockerStrip(snapshot.sleepBlockers)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var diskAlertText: String? {
        guard let disk = snapshot.disk,
              let used = disk.usedFraction,
              used >= 0.88,
              let free = disk.freeBytes
        else {
            return nil
        }
        return "Disk \(Int((used * 100).rounded()))% full (\(MetricFormat.disk(free)) free) · Clean space"
    }

    private func actionStrip(
        icon: String,
        text: String,
        tone: StatusTone,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(tone.color)

                Text(text)
                    .font(AppFont.micro)
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background {
                ObsidianCardBackground(cornerRadius: 9, indicatorTone: tone)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    private func sleepBlockerStrip(_ blockers: [SleepBlocker]) -> some View {
        let primary = blockers[0]
        let extra = blockers.count - 1
        let summary = extra > 0
            ? "\(primary.processName) +\(extra) preventing sleep"
            : "\(primary.processName) preventing \(primary.blocksDisplay ? "display " : "")sleep"

        return Button {
            onInspectPID?(primary.pid)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(AppColors.warning)

                Text(summary)
                    .font(AppFont.micro)
                    .foregroundStyle(Color.white.opacity(0.84))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background {
                ObsidianCardBackground(cornerRadius: 9, isHighlighted: true)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(blockers.map { "\($0.processName) (PID \($0.pid)): \($0.reason)" }.joined(separator: "\n"))
    }

    // MARK: - Memory

    private var memoryTile: some View {
        let memory = snapshot.memory
        let usedFraction: Double? = memory.flatMap {
            $0.totalBytes > 0 ? Double($0.usedBytes) / Double($0.totalBytes) : nil
        }

        return MetricTile(
            icon: "memorychip",
            label: "Memory",
            value: memory.map { MetricFormat.memory($0.usedBytes) } ?? "—",
            detail: memoryDetail(memory),
            tone: memoryTone(memory?.pressure),
            progress: usedFraction,
            isAvailable: memory != nil
        )
    }

    private func memoryDetail(_ memory: MemorySample?) -> String {
        guard let memory else { return "Unavailable" }

        let pressure = memory.pressure.label
        if let swap = memory.swapUsedBytes, swap > 0 {
            return "\(pressure) · \(MetricFormat.memory(swap)) swap"
        }
        return "of \(MetricFormat.memory(memory.totalBytes)) · \(pressure)"
    }

    private func memoryTone(_ pressure: MemoryPressure?) -> StatusTone {
        guard let pressure else { return .neutral }
        switch pressure {
        case .normal: return .success
        case .warning: return .warning
        case .critical: return .critical
        case .unknown: return .neutral
        }
    }

    // MARK: - GPU

    private var gpuTile: some View {
        let gpu = snapshot.gpu

        var parts: [String] = []
        if let model = gpu?.model { parts.append(model) }
        if let cores = gpu?.coreCount { parts.append("\(cores) cores") }

        let detail: String
        if gpu == nil {
            detail = "Unavailable"
        } else if parts.isEmpty {
            detail = "Utilization"
        } else {
            detail = parts.joined(separator: " · ")
        }

        let gpuTone: StatusTone = {
            guard let u = gpu?.utilization else { return .neutral }
            if u >= 0.85 { return .critical }
            if u >= 0.55 { return .warning }
            return .success
        }()

        return MetricTile(
            icon: "rectangle.3.group",
            label: "GPU",
            value: MetricFormat.percent(gpu?.utilization),
            detail: detail,
            tone: gpuTone,
            progress: gpu?.utilization,
            isAvailable: gpu?.utilization != nil
        )
    }

    // MARK: - Disk

    private var diskTile: some View {
        let disk = snapshot.disk
        let value: String
        let detail: String

        if let disk, let free = disk.freeBytes {
            value = "\(MetricFormat.disk(free)) free"

            if let total = disk.totalBytes, let read = disk.readBytesPerSecond {
                detail = "of \(MetricFormat.disk(total)) · R \(MetricFormat.rate(read))"
            } else if let total = disk.totalBytes {
                detail = "of \(MetricFormat.disk(total))"
            } else {
                detail = "Internal disk"
            }
        } else if let disk, let read = disk.readBytesPerSecond {
            value = "R \(MetricFormat.rate(read))"
            detail = "Capacity unavailable"
        } else {
            value = "—"
            detail = "Unavailable"
        }

        return MetricTile(
            icon: "internaldrive",
            label: "Disk",
            value: value,
            detail: detail,
            tone: diskTone(disk),
            progress: disk?.usedFraction,
            isAvailable: disk?.freeBytes != nil || disk?.readBytesPerSecond != nil
        )
    }

    private func diskTone(_ disk: DiskSample?) -> StatusTone {
        guard let used = disk?.usedFraction else { return .neutral }
        if used >= 0.92 { return .critical }
        if used >= 0.80 { return .warning }
        return .success
    }

    // MARK: - Network

    private var networkTile: some View {
        let network = snapshot.network
        let hasRates = network?.downloadBytesPerSecond != nil
        let value = hasRates
            ? "↓ \(MetricFormat.rate(network?.downloadBytesPerSecond))"
            : "—"

        let detail: String
        if network == nil {
            detail = "Unavailable"
        } else if !hasRates {
            detail = "Measuring…"
        } else {
            let upload = "↑ \(MetricFormat.rate(network?.uploadBytesPerSecond))"
            if let name = network?.interfaceName {
                detail = "\(upload) · \(name)"
            } else {
                detail = upload
            }
        }

        return MetricTile(
            icon: "network",
            label: "Network",
            value: value,
            detail: detail,
            isAvailable: hasRates
        )
    }

    // MARK: - Battery

    private var batteryTile: some View {
        let battery = snapshot.battery

        return MetricTile(
            icon: batterySymbol(battery),
            label: "Battery",
            value: battery.map { "\($0.percentage)%" } ?? "—",
            detail: batteryDetail(battery),
            tone: batteryTone(battery),
            progress: battery.map { Double($0.percentage) / 100.0 },
            isAvailable: battery != nil
        )
        .help(batteryHelp(battery))
    }

    private func batterySymbol(_ battery: BatterySample?) -> String {
        guard let battery else { return "battery.0percent" }

        switch battery.percentage {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private func batteryDetail(_ battery: BatterySample?) -> String {
        guard let battery else { return "No battery" }

        let status: String
        if battery.isCharging, let minutes = battery.minutesRemaining {
            status = "Charging · \(MetricFormat.minutes(minutes))"
        } else if battery.isCharging {
            status = "Charging"
        } else if battery.isPluggedIn {
            status = "Plugged in"
        } else if let minutes = battery.minutesRemaining {
            status = "\(MetricFormat.minutes(minutes)) left"
        } else {
            status = "On battery"
        }

        if battery.isPluggedIn, let adapter = battery.adapterWatts {
            if let watts = MetricFormat.watts(battery.powerWatts) {
                return "\(adapter)W AC · \(watts)"
            }
            return "\(status) · \(adapter)W AC"
        }

        if let watts = MetricFormat.watts(battery.powerWatts) {
            return "\(status) · \(watts)"
        }
        if let health = MetricFormat.health(battery.health) {
            return "\(status) · \(health) health"
        }
        return status
    }

    /// Full battery details for the hover tooltip and VoiceOver hint.
    private func batteryHelp(_ battery: BatterySample?) -> String {
        guard let battery else { return "No battery detected" }

        var parts: [String] = []
        parts.append(battery.isCharging ? "Charging" : (battery.isPluggedIn ? "Plugged in, not charging" : "On battery"))
        if let adapter = battery.adapterWatts { parts.append("\(adapter)W adapter") }
        if let watts = MetricFormat.watts(battery.powerWatts) { parts.append("System \(watts)") }
        if let net = battery.batteryNetWatts, abs(net) >= 0.2 {
            let sign = net >= 0 ? "+" : "-"
            parts.append(String(format: "Battery %@%.1f W", sign, abs(net)))
        }
        if let health = MetricFormat.health(battery.health) { parts.append("Health \(health)") }
        if let cycles = battery.cycleCount { parts.append("\(cycles) cycles") }
        if let celsius = battery.temperatureCelsius {
            parts.append(String(format: "%.1f°C", celsius))
        }
        return parts.joined(separator: " · ")
    }

    private func batteryTone(_ battery: BatterySample?) -> StatusTone {
        guard let battery else { return .neutral }
        if battery.isPluggedIn { return .success }
        if battery.percentage <= 15 { return .critical }
        if battery.percentage <= 30 { return .warning }
        return .success
    }

    // MARK: - Thermal

    private var thermalTile: some View {
        let thermal = snapshot.thermal

        let detail: String
        if let thermal {
            detail = thermal.lowPowerMode ? "Low Power Mode on" : thermal.condition.detail
        } else {
            detail = "Unavailable"
        }

        return MetricTile(
            icon: "thermometer.medium",
            label: "Thermal",
            value: thermal?.condition.label ?? "—",
            detail: detail,
            tone: thermalTone(thermal?.condition),
            isAvailable: thermal != nil
        )
    }

    private func thermalTone(_ condition: ThermalCondition?) -> StatusTone {
        guard let condition else { return .neutral }
        switch condition {
        case .nominal: return .success
        case .fair, .serious: return .warning
        case .critical: return .critical
        }
    }
}

#if DEBUG
#Preview("Overview — Black Liquid Glass") {
    OverviewView(
        snapshot: .preview,
        history: [
            0.12, 0.16, 0.14, 0.21, 0.26, 0.19, 0.18, 0.24, 0.31, 0.27,
            0.22, 0.18, 0.20, 0.28, 0.36, 0.30, 0.24, 0.21, 0.19, 0.23,
            0.27, 0.32, 0.29, 0.25, 0.22, 0.24, 0.28, 0.26, 0.23, 0.24
        ]
    )
    .padding(15)
    .frame(width: 380, height: 420)
    .background(AppBackground())
    .preferredColorScheme(.dark)
}
#endif
