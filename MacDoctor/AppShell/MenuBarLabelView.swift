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

            if let readout = compactReadout {
                Text(readout)
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            }
        }
        .accessibilityLabel(accessibilityText)
        .onAppear {
            vitals.startIfNeeded()
        }
    }

    @ViewBuilder
    private var iconView: some View {
        let symbol = settings.menuBarIcon.symbolName
        if let tinted = tintedSymbolImage(name: symbol, tone: vitals.menuBarAlertTone) {
            Image(nsImage: tinted)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
        }
    }

    private var compactReadout: String? {
        switch settings.menuBarReadout {
        case .none:
            return nil

        case .cpu:
            guard let usage = vitals.snapshot.cpu?.totalUsage else { return "—" }
            return "\(Int((min(max(usage, 0), 1) * 100).rounded()))%"

        case .temperature:
            let celsius = vitals.snapshot.temperatures?.hottestCPU
                ?? vitals.snapshot.temperatures?.hottest?.celsius
            return settings.temperatureUnit.format(celsius, decimals: 0)

        case .network:
            guard let down = vitals.snapshot.network?.downloadBytesPerSecond,
                  let up = vitals.snapshot.network?.uploadBytesPerSecond
            else {
                return "—"
            }
            return "↓\(compactRate(down)) ↑\(compactRate(up))"
        }
    }

    private var accessibilityText: String {
        var parts = ["Mac Doctor"]
        if let readout = compactReadout {
            parts.append("\(settings.menuBarReadout.accessibilityName) \(readout)")
        }
        if let alert = vitals.activeAlertSummary {
            parts.append("Alert: \(alert)")
        }
        return parts.joined(separator: ", ")
    }

    /// Renders a non-template palette SF Symbol for warning (amber) and critical
    /// (red) states so macOS MenuBarExtra doesn't force it back to monochrome.
    private func tintedSymbolImage(name: String, tone: StatusTone) -> NSImage? {
        let color: NSColor
        switch tone {
        case .warning:
            color = NSColor(srgbRed: 0.94, green: 0.62, blue: 0.14, alpha: 1.0)
        case .critical:
            color = NSColor(srgbRed: 0.92, green: 0.28, blue: 0.27, alpha: 1.0)
        case .neutral, .success:
            return nil
        }

        let sizeConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let colorConfig = NSImage.SymbolConfiguration(paletteColors: [color])
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: "Mac Doctor"),
              let configured = base.withSymbolConfiguration(sizeConfig.applying(colorConfig))
        else {
            return nil
        }
        configured.isTemplate = false
        return configured
    }

    private func compactRate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1_000 {
            return "\(Int(bytesPerSecond.rounded()))B"
        }
        let kb = bytesPerSecond / 1_000
        if kb < 1_000 {
            return "\(Int(kb.rounded()))K"
        }
        let mb = kb / 1_000
        if mb < 1_000 {
            return mb < 10 ? String(format: "%.1fM", mb) : "\(Int(mb.rounded()))M"
        }
        return String(format: "%.1fG", mb / 1_000)
    }
}
