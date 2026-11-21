//
//  MacDoctor/Views/Overview/MetricTile.swift
//  Mac Doctor
//
//  Smoked-obsidian instrument tile for the 2 × 3 Overview grid. Displays
//  a crisp value, concise detail line, and an optional micro utilization bar
//  in the Claude-orange gradient for instant at-a-glance readability.
//

import SwiftUI

struct MetricTile: View {
    let icon: String
    let label: String
    let value: String
    let detail: String
    var tone: StatusTone = .neutral
    var progress: Double? = nil
    var isAvailable: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var glyphColor: Color {
        Color.white.opacity(0.88)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(glyphColor)
                    .frame(width: 21, height: 21)
                    .background {
                        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    }

                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(Color.white.opacity(0.55))

                Spacer(minLength: 0)

                if tone != .neutral {
                    Circle()
                        .fill(tone.color)
                        .frame(width: 6, height: 6)
                        .shadow(color: tone.color.opacity(0.75), radius: 3)
                        .accessibilityHidden(true)
                }
            }

            Spacer(minLength: 4)

            Text(value)
                .font(AppFont.number(17, weight: .semibold))
                .foregroundStyle(isAvailable ? Color.white : Color.white.opacity(0.40))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .contentTransition(.numericText())

            Text(detail)
                .font(AppFont.micro)
                .foregroundStyle(Color.white.opacity(0.54))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.top, 1)

            if let progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(
                                tone == .neutral
                                    ? AnyShapeStyle(AppGradients.accentHorizontal)
                                    : AnyShapeStyle(tone.color)
                            )
                            .frame(width: max(3, geo.size.width * min(max(progress, 0), 1)))
                            .animation(reduceMotion ? nil : .linear(duration: 0.30), value: progress)
                    }
                }
                .frame(height: 3)
                .padding(.top, 6)
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 82)
        .background {
            ObsidianCardBackground(
                cornerRadius: 14,
                isHighlighted: false,
                indicatorTone: tone
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value). \(detail)")
    }
}
