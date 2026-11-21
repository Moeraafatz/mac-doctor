//
//  MacDoctor/Views/Overview/CPUPanel.swift
//  Mac Doctor
//
//  Black Liquid Glass hero panel for CPU: large rounded percentage, P/E core
//  cluster bars in the Claude-orange grade, and the 60-second trace.
//

import SwiftUI

struct CPUPanel: View {
    let sample: CPUSample?
    let history: [Double]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cpuIndicatorTone: StatusTone {
        guard let usage = sample?.totalUsage else { return .neutral }
        if usage >= 0.85 { return .critical }
        if usage >= 0.50 { return .warning }
        return .success
    }

    var body: some View {
        GlassSurface(cornerRadius: 18, contentPadding: 13) {
            VStack(spacing: 7) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(cpuIndicatorTone.color)
                                .frame(width: 5.5, height: 5.5)
                                .shadow(color: cpuIndicatorTone.color.opacity(0.6), radius: 3)

                            Text("CPU")
                                .font(AppFont.micro)
                                .tracking(1.0)
                                .foregroundStyle(Color.white.opacity(0.65))
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(MetricFormat.percent(sample?.totalUsage))
                                .font(AppFont.metric(30))
                                .foregroundStyle(.white)
                                .contentTransition(.numericText())

                            Text(sample?.brand ?? "Apple Silicon")
                                .font(AppFont.micro)
                                .foregroundStyle(Color.white.opacity(0.50))
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 4)

                    VStack(spacing: 6) {
                        ClusterMeter(
                            label: "P",
                            cores: sample?.performanceCoreCount ?? 0,
                            usage: sample?.performanceUsage,
                            isPerformance: true,
                            reduceMotion: reduceMotion
                        )

                        ClusterMeter(
                            label: "E",
                            cores: sample?.efficiencyCoreCount ?? 0,
                            usage: sample?.efficiencyUsage,
                            isPerformance: false,
                            reduceMotion: reduceMotion
                        )
                    }
                    .frame(width: 126)
                    .padding(.top, 3)
                }

                Sparkline(values: history, indicatorColor: cpuIndicatorTone.color)
                    .frame(height: 30)

                HStack(spacing: 6) {
                    Text("60s live")
                    Spacer(minLength: 4)
                    if let p = sample?.performanceCoreCount, let e = sample?.efficiencyCoreCount, p + e > 0 {
                        Text("\(p)P · \(e)E cores")
                    }
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.45))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let sample else { return "CPU load unavailable" }
        guard let usage = sample.totalUsage else { return "CPU load measuring" }

        var text = "CPU load \(MetricFormat.percent(usage))"
        if let performance = sample.performanceUsage,
           let efficiency = sample.efficiencyUsage {
            text += ", performance cores \(MetricFormat.percent(performance))"
            text += ", efficiency cores \(MetricFormat.percent(efficiency))"
        }
        return text + ", last 60 seconds"
    }
}

// MARK: - Cluster meter

private struct ClusterMeter: View {
    let label: String
    let cores: Int
    let usage: Double?
    let isPerformance: Bool
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text("\(label)\(cores)")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.55))
                .frame(width: 16, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))

                    if let usage {
                        Capsule()
                            .fill(
                                isPerformance
                                    ? AnyShapeStyle(AppGradients.accentHorizontal)
                                    : AnyShapeStyle(AppColors.accentSecondary.opacity(0.85))
                            )
                            .frame(
                                width: max(
                                    3,
                                    geometry.size.width * min(max(usage, 0), 1)
                                )
                            )
                            .animation(
                                reduceMotion ? nil : .linear(duration: 0.30),
                                value: usage
                            )
                    }
                }
            }
            .frame(height: 4.5)

            Text(MetricFormat.percent(usage))
                .font(AppFont.number(9, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.75))
                .frame(width: 26, alignment: .trailing)
        }
        .accessibilityHidden(true)
    }
}
