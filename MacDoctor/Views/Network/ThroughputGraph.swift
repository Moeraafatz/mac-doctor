//
//  MacDoctor/Views/Network/ThroughputGraph.swift
//  Mac Doctor
//
//  Dual-series live upload/download sparkline graph rendered with SwiftUI
//  Canvas. Auto-scales to the rolling 60-second peak with a subtle baseline.
//

import SwiftUI

struct ThroughputGraph: View {
    let points: [ThroughputPoint]

    @Environment(\.colorScheme) private var colorScheme

    private static let uploadColor = AppColors.accentSecondary

    private var peakRate: Double {
        let maxDownload = points.map(\.downloadBytesPerSecond).max() ?? 0
        let maxUpload = points.map(\.uploadBytesPerSecond).max() ?? 0
        // Floor at 10 KB/s so tiny background chatter doesn't look like saturation.
        return max(max(maxDownload, maxUpload), 10_000)
    }

    var body: some View {
        let peak = peakRate

        ZStack(alignment: .topTrailing) {
            Canvas { context, size in
                guard size.width > 4, size.height > 4 else { return }

                // Subtle horizontal baseline + mid-guide.
                for fraction in [0.5, 1.0] {
                    let y = size.height * fraction - 0.5
                    var guide = Path()
                    guide.move(to: CGPoint(x: 0, y: y))
                    guide.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(
                        guide,
                        with: .color(Color.primary.opacity(0.08)),
                        style: StrokeStyle(lineWidth: 0.75, dash: fraction < 1 ? [3, 3] : [])
                    )
                }

                guard points.count >= 2 else { return }

                let stepX = size.width / CGFloat(max(points.count - 1, 1))
                let topInset: CGFloat = 4
                let usableHeight = max(size.height - topInset - 2, 1)

                func yFor(_ rate: Double) -> CGFloat {
                    let normalized = min(max(rate / peak, 0), 1)
                    return size.height - 1 - CGFloat(normalized) * usableHeight
                }

                // Draw download area + stroke.
                var dlLine = Path()
                var dlArea = Path()
                for (idx, point) in points.enumerated() {
                    let pt = CGPoint(x: CGFloat(idx) * stepX, y: yFor(point.downloadBytesPerSecond))
                    if idx == 0 {
                        dlLine.move(to: pt)
                        dlArea.move(to: CGPoint(x: pt.x, y: size.height))
                        dlArea.addLine(to: pt)
                    } else {
                        dlLine.addLine(to: pt)
                        dlArea.addLine(to: pt)
                    }
                }
                dlArea.addLine(to: CGPoint(x: size.width, y: size.height))
                dlArea.closeSubpath()

                context.fill(
                    dlArea,
                    with: .linearGradient(
                        Gradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.04), .clear]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )
                context.stroke(
                    dlLine,
                    with: .linearGradient(
                        Gradient(colors: [Color.white.opacity(0.45), Color.white.opacity(0.90), Color.white]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: size.width, y: 0)
                    ),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                )

                // Draw upload stroke.
                var ulLine = Path()
                for (idx, point) in points.enumerated() {
                    let pt = CGPoint(x: CGFloat(idx) * stepX, y: yFor(point.uploadBytesPerSecond))
                    if idx == 0 {
                        ulLine.move(to: pt)
                    } else {
                        ulLine.addLine(to: pt)
                    }
                }
                context.stroke(
                    ulLine,
                    with: .color(Self.uploadColor.opacity(0.9)),
                    style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)
                )
            }

            if points.count >= 2 {
                Text("Peak \(MetricFormat.rate(peak))")
                    .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background {
                        Capsule().fill(Color.primary.opacity(0.05))
                    }
            }
        }
        .accessibilityHidden(true)
    }
}
