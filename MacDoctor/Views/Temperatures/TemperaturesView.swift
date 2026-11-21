//
//  MacDoctor/Views/Temperatures/TemperaturesView.swift
//  Mac Doctor
//
//  Per-sensor temperatures grouped by component. Every number shown here is
//  a real sensor reading from TemperatureService. Groups that cannot be read
//  say "Unavailable". The MacBook Air is fanless, so there is no fan section.
//

import SwiftUI

struct TemperaturesView: View {
    let sample: TemperatureSample?
    let thermal: ThermalSample?
    var history: [Double] = []

    @AppStorage(TemperaturePreferences.unitKey) private var unit: TemperatureUnit = .celsius
    @AppStorage(TemperaturePreferences.alertThresholdKey) private var threshold: Double = TemperaturePreferences.defaultAlertThreshold
    @State private var expanded: Set<SensorGroup> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                HottestPanel(
                    sample: sample,
                    thermal: thermal,
                    history: history,
                    unit: unit,
                    threshold: threshold
                )

                if let sample, sample.hasReadings {
                    VStack(spacing: 8) {
                        ForEach(SensorGroup.allCases) { group in
                            TemperatureGroupRow(
                                group: group,
                                reading: sample.reading(for: group),
                                unit: unit,
                                threshold: threshold,
                                isExpanded: expanded.contains(group),
                                toggle: { toggle(group) }
                            )
                        }
                    }
                } else {
                    SensorsUnavailablePanel(sample: sample)
                }

                Text("SMC & HID sensors · read-only, no root.")
                    .font(AppFont.micro)
                    .foregroundStyle(Color.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func toggle(_ group: SensorGroup) {
        withAnimation(reduceMotion ? nil : AppMotion.snappy) {
            if expanded.contains(group) {
                expanded.remove(group)
            } else {
                expanded.insert(group)
            }
        }
    }
}

// MARK: - Hottest panel

private struct HottestPanel: View {
    let sample: TemperatureSample?
    let thermal: ThermalSample?
    let history: [Double]
    let unit: TemperatureUnit
    let threshold: Double

    private var thermalTone: StatusTone {
        switch thermal?.condition {
        case .nominal: .success
        case .fair, .serious: .warning
        case .critical: .critical
        case nil: .neutral
        }
    }

    private var normalizedHistory: [Double] {
        history.map { celsius in
            min(max((celsius - 25.0) / 80.0, 0), 1)
        }
    }

    var body: some View {
        let hottest = sample?.hottest
        let tone = TemperaturePreferences.tone(for: hottest?.celsius, threshold: threshold)

        GlassSurface(cornerRadius: 18, contentPadding: 13) {
            VStack(spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("HOTTEST SENSOR")
                            .font(AppFont.micro)
                            .tracking(0.9)
                            .foregroundStyle(Color.white.opacity(0.60))

                        Text(unit.format(hottest?.celsius, decimals: 1))
                            .font(AppFont.metric(30))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())

                        Text(hottest.map { "in \($0.group.title)" } ?? "Unavailable")
                            .font(AppFont.micro)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 6) {
                        StatusBadge(
                            label: thermal.map { "Thermal: \($0.condition.label)" } ?? "Thermal: —",
                            tone: thermalTone
                        )

                        Text(sourceLabel)
                            .font(AppFont.micro)
                            .foregroundStyle(.secondary)
                    }
                }

                if !normalizedHistory.isEmpty {
                    Sparkline(values: normalizedHistory, indicatorColor: tone.color)
                        .frame(height: 24)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(hottest))
    }

    private var sourceLabel: String {
        guard let sample else { return "No sensor access" }
        var sources: [String] = []
        if sample.smcAvailable { sources.append("SMC") }
        if sample.hidAvailable { sources.append("HID") }
        return sources.isEmpty ? "No sensor access" : "Source: " + sources.joined(separator: " · ")
    }

    private func accessibilityLabel(_ hottest: (group: SensorGroup, celsius: Double)?) -> String {
        var text = "Hottest sensor "
        if let hottest {
            text += "\(unit.format(hottest.celsius, decimals: 1)) in \(hottest.group.title)"
        } else {
            text += "unavailable"
        }
        if let thermal {
            text += ". Thermal state \(thermal.condition.label)"
        }
        return text
    }
}

// MARK: - Group row

private struct TemperatureGroupRow: View {
    let group: SensorGroup
    let reading: TemperatureGroupReading?
    let unit: TemperatureUnit
    let threshold: Double
    let isExpanded: Bool
    let toggle: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tone: StatusTone {
        TemperaturePreferences.tone(for: reading?.maximum, threshold: threshold)
    }

    private var glyphColor: Color {
        Color.white.opacity(0.88)
    }

    private var canExpand: Bool {
        (reading?.readings.count ?? 0) > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                header
            }
            .buttonStyle(.plain)
            .disabled(!canExpand)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(canExpand ? (isExpanded ? "Collapse sensor list" : "Show each sensor") : "")

            TemperatureGauge(celsius: reading?.average, tone: tone, reduceMotion: reduceMotion)
                .frame(height: 4)
                .accessibilityHidden(true)

            if isExpanded, let reading {
                SensorGrid(readings: reading.readings, unit: unit, threshold: threshold)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            ObsidianCardBackground(cornerRadius: 14, indicatorTone: tone)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: group.symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(glyphColor)
                .frame(width: 22, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(glyphColor.opacity(0.11))
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(group.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(AppFont.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text(reading.map { unit.format($0.average) } ?? "Unavailable")
                .font(reading == nil ? AppFont.caption : AppFont.number(16, weight: .semibold))
                .foregroundStyle(reading == nil ? Color.secondary : (tone == .warning || tone == .critical ? tone.color : Color.white))
                .contentTransition(.numericText())

            if canExpand {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        guard let reading else { return "Sensor not readable on this Mac" }
        let count = reading.readings.count
        let noun = count == 1 ? "sensor" : "sensors"
        let source = reading.source?.rawValue ?? ""

        if count > 1, let maximum = reading.maximum {
            return "avg of \(count) \(noun) · max \(unit.format(maximum)) · \(source)"
        }
        return "\(count) \(noun) · \(source)"
    }

    private var accessibilityLabel: String {
        guard let reading, let average = reading.average else {
            return "\(group.title): unavailable"
        }
        var text = "\(group.title): average \(unit.format(average))"
        if reading.readings.count > 1, let maximum = reading.maximum {
            text += ", maximum \(unit.format(maximum)), \(reading.readings.count) sensors"
        }
        return text
    }
}

// MARK: - Gauge

/// Linear gauge from 20 °C to 110 °C. Range chosen to cover idle to
/// throttling temperatures on Apple silicon.
private struct TemperatureGauge: View {
    let celsius: Double?
    let tone: StatusTone
    let reduceMotion: Bool

    private static let lower: Double = 20
    private static let upper: Double = 110

    private var fraction: Double? {
        guard let celsius else { return nil }
        return min(max((celsius - Self.lower) / (Self.upper - Self.lower), 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))

                if let fraction {
                    Capsule()
                        .fill(
                            tone == .neutral
                                ? AnyShapeStyle(AppGradients.accentHorizontal)
                                : AnyShapeStyle(tone.color)
                        )
                        .frame(width: max(3, geometry.size.width * fraction))
                        .animation(reduceMotion ? nil : .linear(duration: 0.35), value: fraction)
                }
            }
        }
    }
}

// MARK: - Sensor grid

private struct SensorGrid: View {
    let readings: [SensorReading]
    let unit: TemperatureUnit
    let threshold: Double

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(readings) { reading in
                let tone = TemperaturePreferences.tone(for: reading.celsius, threshold: threshold)

                VStack(alignment: .leading, spacing: 1) {
                    Text(reading.label)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(unit.format(reading.celsius, decimals: 1))
                        .font(AppFont.number(11, weight: .semibold))
                        .foregroundStyle(tone == .neutral ? Color.primary : tone.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                }
                .help(reading.source == .smc ? "SMC key \(reading.id)" : "HID sensor \(reading.id.split(separator: "#").first ?? "")")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(reading.label): \(unit.format(reading.celsius, decimals: 1))")
            }
        }
    }
}

// MARK: - Unavailable

private struct SensorsUnavailablePanel: View {
    let sample: TemperatureSample?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "thermometer.medium.slash")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)

            Text(sample == nil ? "Reading sensors…" : "Temperatures unavailable")
                .font(AppFont.panelTitle)

            Text("Mac Doctor could not read the SMC or HID thermal sensors on this Mac. Nothing is estimated or faked. Details are in Console under com.macdoctor.app › sensors.")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        }
    }
}

#if DEBUG
#Preview("Temperatures Light") {
    TemperaturesView(sample: .preview, thermal: ThermalSample(condition: .nominal, lowPowerMode: false))
        .padding(16)
        .frame(width: 380, height: 420)
        .background(AppBackground())
        .preferredColorScheme(.light)
}

#Preview("Temperatures Dark") {
    TemperaturesView(sample: .preview, thermal: ThermalSample(condition: .fair, lowPowerMode: false))
        .padding(16)
        .frame(width: 380, height: 420)
        .background(AppBackground())
        .preferredColorScheme(.dark)
}
#endif
