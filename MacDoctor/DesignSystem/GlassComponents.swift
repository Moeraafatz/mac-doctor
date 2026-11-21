//
//  MacDoctor/DesignSystem/GlassComponents.swift
//  Mac Doctor
//
//  Pure Black Liquid Glass surfaces with crisp White highlights.
//  Uses macOS 26 Liquid Glass (`glassEffect` + `GlassEffectContainer`) behind
//  availability checks, smoked dark glass on macOS 15, and solid black panels
//  when Reduce Transparency is enabled.
//

import AppKit
import SwiftUI

private struct ForceMaterialGlassKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var forceMaterialGlass: Bool {
        get { self[ForceMaterialGlassKey.self] }
        set { self[ForceMaterialGlassKey.self] = newValue }
    }
}

// MARK: - Background

struct AppBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                AppColors.obsidianCanvas
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)

                AppColors.obsidianCanvas.opacity(0.88)
            }

            // Subtle white liquid-glass light bloom from top-left.
            RadialGradient(
                colors: [
                    Color.white.opacity(reduceTransparency ? 0.04 : 0.08),
                    .clear
                ],
                center: UnitPoint(x: 0.10, y: 0.0),
                startRadius: 0,
                endRadius: 300
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Black Liquid Glass hero surface

struct GlassSurface<Content: View>: View {
    let cornerRadius: CGFloat
    let contentPadding: CGFloat
    let content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.forceMaterialGlass) private var forceMaterialGlass
    @Environment(\.colorSchemeContrast) private var contrast

    init(
        cornerRadius: CGFloat = AppRadius.large,
        contentPadding: CGFloat = AppSpacing.lg,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.contentPadding = contentPadding
        self.content = content()
    }

    var body: some View {
        surface
            .overlay {
                if !reduceTransparency {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.075), .clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        AppGradients.glassRim,
                        lineWidth: contrast == .increased ? 1.5 : 1
                    )
            }
            .shadow(color: .black.opacity(0.48), radius: 16, x: 0, y: 8)
    }

    @ViewBuilder
    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *), !reduceTransparency, !forceMaterialGlass {
            content
                .padding(contentPadding)
                .glassEffect(.regular.tint(Color.black.opacity(0.52)), in: shape)
        } else {
            content
                .padding(contentPadding)
                .background {
                    if reduceTransparency {
                        shape.fill(AppColors.solidPanel)
                    } else {
                        ZStack {
                            shape.fill(.ultraThinMaterial)
                            shape.fill(AppColors.obsidianPanel.opacity(0.80))
                        }
                    }
                }
        }
    }
}

/// Secondary black glass card used by tiles, rows, and diagnostic panels.
struct ObsidianCardBackground: View {
    var cornerRadius: CGFloat = AppRadius.medium
    var isHighlighted: Bool = false
    var indicatorTone: StatusTone = .neutral

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.forceMaterialGlass) private var forceMaterialGlass
    @Environment(\.colorSchemeContrast) private var contrast

    private var strokeStyle: AnyShapeStyle {
        if indicatorTone == .warning || indicatorTone == .critical {
            return AnyShapeStyle(indicatorTone.color.opacity(0.40))
        }
        if isHighlighted {
            return AnyShapeStyle(Color.white.opacity(0.24))
        }
        return AnyShapeStyle(AppGradients.tileRim)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if reduceTransparency {
                shape.fill(AppColors.solidPanel)
            } else {
                shape.fill(AppColors.obsidianTile.opacity(isHighlighted ? 0.90 : 0.76))
                shape.fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.04), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .overlay {
            shape.strokeBorder(
                strokeStyle,
                lineWidth: contrast == .increased ? 1.4 : 1
            )
        }
    }
}

/// Capsule-shaped black liquid glass used by the tab bar and compact pills.
struct GlassCapsule<Content: View>: View {
    let contentPadding: EdgeInsets
    let content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.forceMaterialGlass) private var forceMaterialGlass
    @Environment(\.colorSchemeContrast) private var contrast

    init(
        contentPadding: EdgeInsets = EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4),
        @ViewBuilder content: () -> Content
    ) {
        self.contentPadding = contentPadding
        self.content = content()
    }

    var body: some View {
        surface
            .overlay {
                Capsule()
                    .strokeBorder(
                        AppGradients.glassRim,
                        lineWidth: contrast == .increased ? 1.5 : 1
                    )
            }
            .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)
    }

    @ViewBuilder
    private var surface: some View {
        if #available(macOS 26.0, *), !reduceTransparency, !forceMaterialGlass {
            content
                .padding(contentPadding)
                .glassEffect(.regular.tint(Color.black.opacity(0.56)), in: Capsule())
        } else {
            content
                .padding(contentPadding)
                .background {
                    if reduceTransparency {
                        Capsule().fill(AppColors.solidPanel)
                    } else {
                        ZStack {
                            Capsule().fill(.ultraThinMaterial)
                            Capsule().fill(AppColors.obsidianPanel.opacity(0.84))
                        }
                    }
                }
        }
    }
}

struct LiquidGlassGroup<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.forceMaterialGlass) private var forceMaterialGlass

    init(spacing: CGFloat = 10, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *), !reduceTransparency, !forceMaterialGlass {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

// MARK: - Small components

struct StatusBadge: View {
    let label: String
    var tone: StatusTone = .neutral

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tone.color)
                .frame(width: 6, height: 6)
                .shadow(color: tone == .neutral ? .clear : tone.color.opacity(0.65), radius: 3)

            Text(label)
                .font(AppFont.micro)
                .foregroundStyle(tone == .neutral ? Color.white.opacity(0.75) : tone.color)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background {
            Capsule()
                .fill(tone == .neutral ? Color.white.opacity(0.06) : tone.color.opacity(0.14))
        }
        .overlay {
            Capsule()
                .strokeBorder(
                    tone == .neutral ? Color.white.opacity(0.12) : tone.color.opacity(0.32),
                    lineWidth: 1
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(label)")
    }
}

struct SectionHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(AppFont.panelTitle)
                .foregroundStyle(.primary)

            Spacer(minLength: AppSpacing.sm)

            if let detail {
                Text(detail)
                    .font(AppFont.micro)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct VitalTrace: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        let width = rect.width
        let height = rect.height

        path.move(to: CGPoint(x: 0, y: midY))
        path.addLine(to: CGPoint(x: width * 0.16, y: midY))
        path.addLine(to: CGPoint(x: width * 0.21, y: midY - height * 0.10))
        path.addLine(to: CGPoint(x: width * 0.26, y: midY))
        path.addLine(to: CGPoint(x: width * 0.33, y: midY))
        path.addLine(to: CGPoint(x: width * 0.38, y: midY + height * 0.08))
        path.addLine(to: CGPoint(x: width * 0.42, y: midY - height * 0.42))
        path.addLine(to: CGPoint(x: width * 0.46, y: midY + height * 0.28))
        path.addLine(to: CGPoint(x: width * 0.51, y: midY))
        path.addLine(to: CGPoint(x: width * 0.62, y: midY))
        path.addLine(to: CGPoint(x: width * 0.67, y: midY - height * 0.10))
        path.addLine(to: CGPoint(x: width * 0.72, y: midY))
        path.addLine(to: CGPoint(x: width, y: midY))

        return path
    }
}

// MARK: - Button styles

struct QuietIconButtonStyle: ButtonStyle {
    var reduceMotion: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(configuration.isPressed ? Color.white : Color.white.opacity(0.75))
            .frame(width: 28, height: 28)
            .background {
                Circle()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.18 : 0.07))
            }
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
            }
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}

struct FooterButtonStyle: ButtonStyle {
    var reduceMotion: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.micro)
            .foregroundStyle(configuration.isPressed ? Color.white : Color.white.opacity(0.75))
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background {
                Capsule()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.18 : 0.07))
            }
            .overlay {
                Capsule()
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
            }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}
