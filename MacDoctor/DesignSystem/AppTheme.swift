//
//  MacDoctor/DesignSystem/AppTheme.swift
//  Mac Doctor
//
//  Monochrome Black Liquid Glass + crisp White secondary hierarchy.
//  Color is reserved strictly for live health indicators:
//  • Green  (#30D158) — healthy / cool / normal
//  • Orange (#FF9F0A) — elevated / warm / warning
//  • Red    (#FF453A) — critical / hot / danger
//

import SwiftUI

enum AppColors {
    /// Monochrome primary accent (pure white in dark Liquid Glass).
    static let accent = Color("AccentColor")
    static let accentGlow = Color.white
    static let accentDeep = Color(white: 0.72)
    /// Muted silver-white for secondary series (e.g. upload rate, E-cores).
    static let accentSecondary = Color.white.opacity(0.48)

    /// Semantic indicator colors ONLY (Green / Orange / Red).
    static let success = Color(red: 0.188, green: 0.820, blue: 0.345)   // #30D158
    static let warning = Color(red: 1.000, green: 0.624, blue: 0.039)   // #FF9F0A
    static let critical = Color(red: 1.000, green: 0.271, blue: 0.227)  // #FF453A

    /// Deep black Liquid Glass base tones.
    static let obsidianCanvas = Color(red: 0.025, green: 0.025, blue: 0.030)
    static let obsidianPanel = Color(red: 0.065, green: 0.065, blue: 0.072)
    static let obsidianTile = Color(red: 0.082, green: 0.082, blue: 0.090)

    /// High-contrast monochrome foreground for labels and glyphs.
    static func accentForeground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white : Color(white: 0.12)
    }

    static let glassStroke = Color.white.opacity(0.12)
    static let glassHighlight = Color.white.opacity(0.24)
    static let hairline = Color.white.opacity(0.10)
    static let solidPanel = Color(red: 0.090, green: 0.090, blue: 0.098)
}

enum AppGradients {
    /// Crisp monochrome dark-chrome fill for the app mark.
    static var accent: LinearGradient {
        LinearGradient(
            colors: [Color(white: 0.20), Color(white: 0.07)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Clean silver-to-white horizontal gradient for neutral bars and traces.
    static var accentHorizontal: LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(0.55), Color.white],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Specular white rim highlight for Black Liquid Glass surfaces.
    static var glassRim: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.24),
                Color.white.opacity(0.06),
                Color.white.opacity(0.12)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var tileRim: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.13),
                Color.white.opacity(0.04)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var vitalTrace: LinearGradient {
        LinearGradient(
            colors: [.clear, Color.white.opacity(0.85), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

enum AppFont {
    static let screenTitle = Font.system(size: 16.5, weight: .bold)
    static let panelTitle = Font.system(size: 13.5, weight: .semibold)
    static let body = Font.system(size: 12, weight: .regular)
    static let caption = Font.system(size: 11, weight: .regular)
    static let micro = Font.system(size: 9.5, weight: .medium)
    static let tab = Font.system(size: 9.5, weight: .semibold)

    static func metric(_ size: CGFloat = 30) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }

    static func number(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

enum AppSpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
}

enum AppRadius {
    static let small: CGFloat = 9
    static let medium: CGFloat = 14
    static let large: CGFloat = 20
}

enum AppLayout {
    static let popoverWidth: CGFloat = 380
    static let popoverHeight: CGFloat = 560
    static let horizontalInset: CGFloat = 15
}

enum AppMotion {
    static var snappy: Animation {
        .spring(response: 0.28, dampingFraction: 0.84)
    }

    static var gentle: Animation {
        .easeInOut(duration: 0.18)
    }
}

enum StatusTone: Equatable {
    case neutral
    case success
    case warning
    case critical

    var color: Color {
        switch self {
        case .neutral: Color.white.opacity(0.65)
        case .success: AppColors.success
        case .warning: AppColors.warning
        case .critical: AppColors.critical
        }
    }
}
