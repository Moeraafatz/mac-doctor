//
//  MacDoctor/Views/Processes/ProcessRowView.swift
//  Mac Doctor
//
//  Single row in the Processes (Task Manager) list. Displays app icon, name,
//  PID, CPU %, memory, energy (measured or clearly labelled "est."), per-process
//  network throughput, and a policy-aware Quit / Force Quit / Relaunch control.
//

import AppKit
import SwiftUI

struct ProcessRowView: View {
    let entry: ProcessEntry
    let icon: NSImage
    let sortKey: ProcessSortKey
    let quitAttempted: Bool
    let nettopAvailable: Bool
    var sleepBlockerReason: String? = nil
    var isChildRow: Bool = false
    let onPrimaryAction: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var cpuTone: StatusTone {
        if entry.cpuPercent >= 85 { return .critical }
        if entry.cpuPercent >= ProcessThresholds.sustainedCPUPercent { return .warning }
        return .neutral
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(entry.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text("PID \(String(entry.pid))")
                        .font(AppFont.number(9, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.48))
                        .lineLimit(1)

                    if let sleepBlockerReason {
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(AppColors.warning)
                            .help("Preventing sleep: \(sleepBlockerReason)")
                            .accessibilityLabel("Preventing sleep")
                    }

                    if entry.isOffender {
                        Circle()
                            .fill(AppColors.warning)
                            .frame(width: 5, height: 5)
                            .accessibilityLabel("Top offender")
                    }

                    Spacer(minLength: 2)
                }

                HStack(spacing: 8) {
                    metricChip(
                        label: "CPU",
                        value: formatCPU(entry.cpuPercent),
                        highlighted: sortKey == .cpu,
                        tone: cpuTone
                    )

                    metricChip(
                        label: "MEM",
                        value: entry.memoryBytes > 0 ? MetricFormat.memory(entry.memoryBytes) : "—",
                        highlighted: sortKey == .memory,
                        tone: .neutral
                    )

                    metricChip(
                        label: "ENG",
                        value: entry.energy.compactLabel,
                        highlighted: sortKey == .energy,
                        tone: entry.energy.isHighEnergy ? .warning : .neutral
                    )

                    metricChip(
                        label: "NET",
                        value: formatNetwork(),
                        highlighted: sortKey == .network,
                        tone: entry.totalNetworkRate >= ProcessThresholds.heavyNetworkBytesPerSecond
                            ? .warning
                            : .neutral
                    )
                }
            }

            actionControl
        }
        .padding(.leading, isChildRow ? 14 : 9)
        .padding(.trailing, 9)
        .padding(.vertical, isChildRow ? 5.5 : 7)
        .background {
            ObsidianCardBackground(cornerRadius: 12, isHighlighted: entry.isOffender || isHovering)
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .help(rowTooltip)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Metric chip

    private func metricChip(
        label: String,
        value: String,
        highlighted: Bool,
        tone: StatusTone
    ) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(highlighted ? AppColors.accentForeground(for: colorScheme) : Color.secondary.opacity(0.75))

            Text(value)
                .font(AppFont.number(9.5, weight: highlighted ? .semibold : .medium))
                .foregroundStyle(tone == .neutral ? (highlighted ? Color.primary : Color.secondary) : tone.color)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Action control

    @ViewBuilder
    private var actionControl: some View {
        switch entry.policy {
        case .allowed:
            if quitAttempted {
                Button(action: onPrimaryAction) {
                    Text("Force")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background {
                            Capsule().fill(AppColors.critical)
                        }
                }
                .buttonStyle(.plain)
                .help("Still running — click to Force Quit \(entry.name) (requires confirmation)")
                .accessibilityLabel("Force quit \(entry.name)")
            } else {
                Button(action: onPrimaryAction) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isHovering ? AppColors.critical : Color.secondary.opacity(0.65))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
                .help("Quit \(entry.name) (PID \(entry.pid))")
                .accessibilityLabel("Quit \(entry.name)")
            }

        case .relaunchOnly(let reason):
            Button(action: onPrimaryAction) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isHovering ? AppColors.accentForeground(for: colorScheme) : Color.secondary.opacity(0.75))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(reason)
            .accessibilityLabel("Relaunch Finder")

        case .blocked(let reason):
            // Wrap the disabled button so `.help` still surfaces the tooltip on hover.
            ZStack {
                Button(action: {}) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.secondary.opacity(0.45))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(true)
            }
            .contentShape(Rectangle())
            .help(reason)
            .accessibilityLabel("\(entry.name) cannot be quit: \(reason)")
        }
    }

    // MARK: - Formatting

    private func formatCPU(_ percent: Double) -> String {
        if percent < 0.05 { return "0%" }
        if percent < 10 { return String(format: "%.1f%%", percent) }
        return String(format: "%.0f%%", percent)
    }

    private func formatNetwork() -> String {
        guard nettopAvailable else { return "—" }
        let total = entry.totalNetworkRate
        if total >= 1 {
            return compactBytesPerSec(total)
        }
        return "0 B/s"
    }

    private func compactBytesPerSec(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1_000 {
            return "\(Int(bytesPerSecond.rounded()))B"
        }
        let kb = bytesPerSecond / 1_000
        if kb < 1_000 {
            return kb < 10 ? String(format: "%.1fK", kb) : "\(Int(kb.rounded()))K"
        }
        let mb = kb / 1_000
        if mb < 1_000 {
            return mb < 10 ? String(format: "%.1fM", mb) : "\(Int(mb.rounded()))M"
        }
        return String(format: "%.1fG", mb / 1_000)
    }

    private var rowTooltip: String {
        var lines: [String] = []
        lines.append("\(entry.name) (PID \(entry.pid)) · \(entry.isGUIApp ? "App" : "Background process")")
        if let path = entry.executablePath {
            lines.append(path)
        }
        lines.append("CPU: \(String(format: "%.1f%%", entry.cpuPercent)) · Memory: \(MetricFormat.memory(entry.memoryBytes))")
        lines.append("Energy: \(entry.energy.detailedLabel)")
        if nettopAvailable, entry.hasNetworkSample {
            let down = MetricFormat.rate(entry.networkBytesInPerSec)
            let up = MetricFormat.rate(entry.networkBytesOutPerSec)
            let totIn = entry.networkTotalBytesIn.map { MetricFormat.disk($0) } ?? "—"
            let totOut = entry.networkTotalBytesOut.map { MetricFormat.disk($0) } ?? "—"
            lines.append("Network: ↓ \(down)  ↑ \(up) (total ↓ \(totIn), ↑ \(totOut))")
        } else if !nettopAvailable {
            lines.append("Network: Unavailable (nettop failed)")
        }
        if !entry.offenderReasons.isEmpty {
            lines.append("Flagged: " + entry.offenderReasons.map(\.shortLabel).joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}
