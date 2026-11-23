//
//  MacDoctor/AppShell/MenuBarLabelView.swift
//  Mac Doctor
//
//  Menu bar icon plus optional user-selected live readout (CPU %, temperature,
//  or compact network up/down). Uses a non-template palette NSImage when a
//  threshold alert is active so macOS MenuBarExtra preserves amber/red tinting,
//  and a normal adaptive template SF Symbol when healthy.
//

import AppKit
import SwiftUI

struct MenuBarLabelView: View {
    let vitals: VitalsStore
    let settings: SettingsStore

    var body: some View {
        HStack(spacing: 4) {
            iconView

            if let readout = vitals.menuBarDisplayText {
                Text(readout)
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            }
        }
        .accessibilityLabel(accessibilityText)
        .onAppear {
            vitals.refreshMenuBarDisplayText()
            vitals.startIfNeeded()
        }
        .onChange(of: settings.menuBarReadout) { _, _ in
            vitals.refreshMenuBarDisplayText()
            vitals.reschedulePolling()
        }
        .onChange(of: settings.refreshInterval) { _, _ in
            vitals.reschedulePolling()
        }
        .onChange(of: settings.temperatureUnit) { _, _ in
            vitals.refreshMenuBarDisplayText()
        }
    }

    @ViewBuilder
    private var iconView: some View {
        let symbol = settings.menuBarIcon.symbolName
        if let tinted = MenuBarSymbolCache.tintedImage(name: symbol, tone: vitals.menuBarAlertTone) {
            Image(nsImage: tinted)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
        }
    }

    private var accessibilityText: String {
        var parts = ["Mac Doctor"]
        if let readout = vitals.menuBarDisplayText {
            parts.append("\(settings.menuBarReadout.accessibilityName) \(readout)")
        }
        if let alert = vitals.activeAlertSummary {
            parts.append("Alert: \(alert)")
        }
        return parts.joined(separator: ", ")
    }
}

@MainActor
private enum MenuBarSymbolCache {
    private static var cache: [String: NSImage] = [:]

    static func tintedImage(name: String, tone: StatusTone) -> NSImage? {
        let color: NSColor
        let toneKey: String
        switch tone {
        case .warning:
            color = NSColor(srgbRed: 0.94, green: 0.62, blue: 0.14, alpha: 1.0)
            toneKey = "warn"
        case .critical:
            color = NSColor(srgbRed: 0.92, green: 0.28, blue: 0.27, alpha: 1.0)
            toneKey = "crit"
        case .neutral, .success:
            return nil
        }

        let key = "\(name):\(toneKey)"
        if let cached = cache[key] {
            return cached
        }

        let sizeConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let colorConfig = NSImage.SymbolConfiguration(paletteColors: [color])
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: "Mac Doctor"),
              let configured = base.withSymbolConfiguration(sizeConfig.applying(colorConfig))
        else {
            return nil
        }
        configured.isTemplate = false
        cache[key] = configured
        return configured
    }
}
