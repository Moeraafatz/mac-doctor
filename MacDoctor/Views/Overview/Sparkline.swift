//
//  MacDoctor/Views/Overview/Sparkline.swift
//  Mac Doctor
//
//  Right-aligned 60-second CPU trace rendered with a luminous Claude-orange
//  gradient stroke, soft ember under-glow, and a live leading pulse dot.
//

import SwiftUI

struct Sparkline: View {
    let values: [Double]
    var capacity: Int = 30
    var indicatorColor: Color = .white

    var body: some View {
        Canvas { context, size in
            let baselineY = size.height - 0.5
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: baselineY))
            baseline.addLine(to: CGPoint(x: size.width, y: baselineY))
            context.stroke(
                baseline,
                with: .color(Color.white.opacity(0.08)),
                lineWidth: 0.6
            )

            guard !values.isEmpty, size.width > 0, size.height > 0 else {
                return
            }

            let horizontalInset: CGFloat = 3
            let topInset: CGFloat = 4
            let usableWidth = max(size.width - horizontalInset * 2, 1)
            let usableHeight = max(size.height - topInset - 2, 1)
            let step = usableWidth / CGFloat(max(capacity - 1, 1))

            if values.count == 1 {
                let value = min(max(values[0], 0), 1)
                let center = CGPoint(
                    x: horizontalInset + usableWidth,
                    y: topInset + (1 - CGFloat(value)) * usableHeight
                )
                drawPulseDot(at: center, in: &context)
                return
            }

            let startX = horizontalInset + usableWidth - CGFloat(values.count - 1) * step

            func point(at index: Int) -> CGPoint {
                let value = min(max(values[index], 0), 1)
                return CGPoint(
                    x: startX + CGFloat(index) * step,
                    y: topInset + (1 - CGFloat(value)) * usableHeight
                )
            }

            var line = Path()
            var area = Path()
            let first = point(at: 0)
            line.move(to: first)
            area.move(to: CGPoint(x: first.x, y: size.height))
            area.addLine(to: first)

            for index in 1..<values.count {
                let next = point(at: index)
                line.addLine(to: next)
                area.addLine(to: next)
            }

            let last = point(at: values.count - 1)
            area.addLine(to: CGPoint(x: last.x, y: size.height))
            area.closeSubpath()

            context.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [
                        Color.white.opacity(0.18),
                        Color.white.opacity(0.04),
                        .clear
                    ]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            context.stroke(
                line,
                with: .linearGradient(
                    Gradient(colors: [
                        Color.white.opacity(0.38),
                        Color.white.opacity(0.85),
                        Color.white
                    ]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: size.width, y: 0)
                ),
                style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
            )

            drawPulseDot(at: last, in: &context)
        }
        .accessibilityHidden(true)
    }

    private func drawPulseDot(at center: CGPoint, in context: inout GraphicsContext) {
        let halo = CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9)
        context.fill(Path(ellipseIn: halo), with: .color(indicatorColor.opacity(0.35)))

        let core = CGRect(x: center.x - 2.4, y: center.y - 2.4, width: 4.8, height: 4.8)
        context.fill(Path(ellipseIn: core), with: .color(indicatorColor))
    }
}
