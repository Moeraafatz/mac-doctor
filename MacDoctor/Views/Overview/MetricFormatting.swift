//
//  MacDoctor/Views/Overview/MetricFormatting.swift
//  Mac Doctor
//
//  Compact, predictable formatting for an instrument panel. Memory uses
//  binary units (what Activity Monitor calls GB); storage and throughput use
//  decimal units (what Finder and network tools use).
//

import Foundation

enum MetricFormat {
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        let clamped = min(max(value, 0), 1)
        return "\(Int((clamped * 100).rounded()))%"
    }

    static func memory(_ bytes: UInt64) -> String {
        scaled(bytes, base: 1_024)
    }

    static func disk(_ bytes: UInt64) -> String {
        scaled(bytes, base: 1_000)
    }

    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else {
            return "—"
        }

        if bytesPerSecond < 1_000 {
            return "\(Int(bytesPerSecond.rounded())) B/s"
        }

        let kilobytes = bytesPerSecond / 1_000
        if kilobytes < 1_000 {
            return String(format: "%.1f KB/s", kilobytes)
        }

        let megabytes = kilobytes / 1_000
        if megabytes < 1_000 {
            return String(format: "%.1f MB/s", megabytes)
        }

        return String(format: "%.2f GB/s", megabytes / 1_000)
    }

    static func minutes(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "—" }
        if minutes >= 60 {
            return String(format: "%d:%02d", minutes / 60, minutes % 60)
        }
        return "\(minutes)m"
    }

    static func watts(_ watts: Double?) -> String? {
        guard let watts, watts.isFinite, watts > 0 else { return nil }
        return watts < 10 ? String(format: "%.1f W", watts) : "\(Int(watts.rounded())) W"
    }

    static func health(_ fraction: Double?) -> String? {
        guard let fraction, fraction.isFinite else { return nil }
        return "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    private static func scaled(_ bytes: UInt64, base: Double) -> String {
        let value = Double(bytes)
        guard value >= base else { return "\(Int(value)) B" }

        let units = ["KB", "MB", "GB", "TB", "PB"]
        var scaled = value / base
        var index = 0

        while scaled >= base, index < units.count - 1 {
            scaled /= base
            index += 1
        }

        return String(format: "%.1f %@", scaled, units[index])
    }
}
