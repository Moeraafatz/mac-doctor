//
//  MacDoctor/Models/ProcessMetrics.swift
//  Mac Doctor
//
//  Immutable, Sendable models for the Processes (Task Manager) tab, plus the
//  hard safety blocklist that prevents critical macOS daemons and Mac Doctor
//  itself from ever being terminated.
//

import Darwin
import Foundation

// MARK: - Sorting

enum ProcessSortKey: String, CaseIterable, Identifiable, Sendable {
    case cpu
    case memory
    case energy
    case network

    var id: Self { self }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .energy: "Energy"
        case .network: "Network"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .energy: "bolt.fill"
        case .network: "arrow.up.arrow.down"
        }
    }
}

// MARK: - Safety blocklist and policy

enum ProcessTerminationPolicy: Sendable, Equatable {
    /// Owned by the current user and not on the hard blocklist.
    case allowed
    /// Finder may only be relaunched, never force-killed.
    case relaunchOnly(reason: String)
    /// Cannot be ended from Mac Doctor; button stays disabled with tooltip.
    case blocked(reason: String)

    var isKillable: Bool {
        if case .allowed = self { return true }
        return false
    }

    var isRelaunchOnly: Bool {
        if case .relaunchOnly = self { return true }
        return false
    }

    var tooltip: String {
        switch self {
        case .allowed:
            "Quit process"
        case .relaunchOnly(let reason), .blocked(let reason):
            reason
        }
    }
}

enum ProcessBlocklist {
    /// Hard blocklist of critical macOS processes that can NEVER be killed.
    /// Finder is handled separately as relaunch-only.
    static let protectedNames: Set<String> = [
        "kernel_task",
        "launchd",
        "WindowServer",
        "loginwindow",
        "logd",
        "opendirectoryd",
        "coreaudiod",
        "securityd",
        "trustd",
        "mds",
        "mds_stores",
        "systemstats",
        "SystemUIServer",
        "Dock",
        "Mac Doctor",
        "MacDoctor"
    ]

    static let protectedBundleIdentifiers: Set<String> = [
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.loginwindow",
        "com.macdoctor.app"
    ]

    static let finderName = "Finder"
    static let finderBundleIdentifier = "com.apple.finder"

    static func policy(
        pid: pid_t,
        executableName: String,
        displayName: String,
        bundleIdentifier: String?,
        uid: uid_t,
        currentUID: uid_t = getuid(),
        selfPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> ProcessTerminationPolicy {
        if pid == selfPID || bundleIdentifier == "com.macdoctor.app" {
            return .blocked(reason: "Mac Doctor cannot quit itself")
        }

        if pid <= 1 {
            return .blocked(reason: "Protected macOS kernel or init process")
        }

        if executableName == finderName
            || displayName == finderName
            || bundleIdentifier == finderBundleIdentifier {
            if uid != currentUID {
                return .blocked(reason: "Owned by another user")
            }
            return .relaunchOnly(reason: "Finder cannot be killed — relaunch only")
        }

        if protectedNames.contains(executableName)
            || protectedNames.contains(displayName)
            || (bundleIdentifier.map { protectedBundleIdentifiers.contains($0) } ?? false) {
            return .blocked(reason: "Protected macOS system process — cannot be quit")
        }

        if uid != currentUID {
            return .blocked(reason: "Only processes owned by the current user can be quit")
        }

        return .allowed
    }
}

// MARK: - Energy

enum ProcessEnergy: Sendable, Equatable {
    /// Derived from `proc_pid_rusage` (`ri_energy_nj` delta) in watts.
    case measuredWatts(Double)
    /// Fallback estimate from CPU %, idle wakeups, and disk I/O when
    /// `ri_energy_nj` is unavailable. Always labelled "estimated" in the UI.
    case estimated(Double)
    case unavailable

    var isEstimated: Bool {
        if case .estimated = self { return true }
        return false
    }

    /// Sortable value on a common scale (roughly milliwatts / energy impact).
    var sortValue: Double {
        switch self {
        case .measuredWatts(let watts): watts * 100
        case .estimated(let score): score
        case .unavailable: -1
        }
    }

    var isHighEnergy: Bool {
        switch self {
        case .measuredWatts(let watts): watts >= ProcessThresholds.highEnergyWatts
        case .estimated(let score): score >= ProcessThresholds.highEstimatedEnergy
        case .unavailable: false
        }
    }

    var compactLabel: String {
        switch self {
        case .measuredWatts(let watts):
            if watts < 0.05 { return "0.0 W" }
            if watts < 10 { return String(format: "%.1f W", watts) }
            return String(format: "%.0f W", watts)
        case .estimated(let score):
            return String(format: "%.0f est.", score)
        case .unavailable:
            return "—"
        }
    }

    var detailedLabel: String {
        switch self {
        case .measuredWatts(let watts):
            String(format: "%.2f W (rusage)", watts)
        case .estimated(let score):
            String(format: "%.1f impact (estimated)", score)
        case .unavailable:
            "Unavailable"
        }
    }
}

// MARK: - Thresholds & Offenders

enum ProcessThresholds {
    /// CPU % (per-core scale, Activity Monitor style) required to start a sustained streak.
    static let sustainedCPUPercent: Double = 50
    /// Seconds above `sustainedCPUPercent` before flagging in Top Offenders.
    static let sustainedCPUDuration: TimeInterval = 60
    /// Measured power draw (watts) considered high energy for a single process.
    static let highEnergyWatts: Double = 3.0
    /// Estimated energy score considered high energy when `ri_energy_nj` is unavailable.
    static let highEstimatedEnergy: Double = 50
    /// Combined network throughput (bytes/sec) considered heavy network activity.
    static let heavyNetworkBytesPerSecond: Double = 2_000_000 // 2 MB/s
    /// Memory growth within a 5-minute window considered a runaway spike.
    static let memoryGrowthBytes: UInt64 = 500_000_000 // 500 MB
    static let memoryGrowthWindowSeconds: TimeInterval = 300
}

enum OffenderReason: Sendable, Equatable {
    case sustainedCPU(percent: Double, duration: TimeInterval)
    case highEnergy(label: String, isEstimated: Bool)
    case heavyNetwork(bytesPerSecond: Double)
    case memoryGrowth(deltaBytes: UInt64)

    var shortLabel: String {
        switch self {
        case .sustainedCPU(let percent, let duration):
            let mins = Int(duration) / 60
            let secs = Int(duration) % 60
            let time = mins > 0 ? "\(mins)m\(secs > 0 ? " \(secs)s" : "")" : "\(secs)s"
            return "\(Int(percent.rounded()))% CPU for \(time)"
        case .highEnergy(let label, let isEstimated):
            return isEstimated ? "High energy (\(label), estimated)" : "High energy (\(label))"
        case .heavyNetwork(let rate):
            return "Heavy network (\(MetricFormat.rate(rate)))"
        case .memoryGrowth(let deltaBytes):
            return "+\(MetricFormat.memory(deltaBytes)) RAM spike"
        }
    }
}

struct ProcessOffender: Identifiable, Sendable, Equatable {
    var id: pid_t { pid }
    var pid: pid_t
    var name: String
    var reasons: [OffenderReason]
}

// MARK: - Process Entry & Snapshot

struct ProcessEntry: Identifiable, Sendable, Equatable {
    var id: pid_t { pid }
    var pid: pid_t
    var name: String
    var executableName: String
    var executablePath: String?
    var bundleURL: URL?
    var bundleIdentifier: String?
    var uid: uid_t
    var isGUIApp: Bool
    /// Activity Monitor scale: 100.0 = one full CPU core busy.
    var cpuPercent: Double
    var memoryBytes: UInt64
    var energy: ProcessEnergy
    var networkBytesInPerSec: Double?
    var networkBytesOutPerSec: Double?
    var networkTotalBytesIn: UInt64?
    var networkTotalBytesOut: UInt64?
    var sustainedHighCPUSeconds: TimeInterval
    var policy: ProcessTerminationPolicy
    var offenderReasons: [OffenderReason]

    var totalNetworkRate: Double {
        (networkBytesInPerSec ?? 0) + (networkBytesOutPerSec ?? 0)
    }

    var totalNetworkCumulative: UInt64 {
        (networkTotalBytesIn ?? 0) + (networkTotalBytesOut ?? 0)
    }

    var hasNetworkSample: Bool {
        networkBytesInPerSec != nil || networkBytesOutPerSec != nil
            || networkTotalBytesIn != nil || networkTotalBytesOut != nil
    }

    var isOffender: Bool {
        !offenderReasons.isEmpty
    }

    /// Outermost `.app` bundle path (e.g. `/Applications/Microsoft Edge.app`)
    /// so embedded helpers (`Microsoft Edge Helper.app`) group under their parent app.
    var rootAppBundlePath: String? {
        let candidate = bundleURL?.path ?? executablePath
        guard let candidate, let range = candidate.range(of: ".app") else { return nil }
        return String(candidate[..<range.upperBound])
    }
}

struct ProcessGroup: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let primaryEntry: ProcessEntry
    let members: [ProcessEntry]
    let totalCPUPercent: Double
    let totalMemoryBytes: UInt64
    let totalEnergy: ProcessEnergy
    let totalNetworkBytesInPerSec: Double?
    let totalNetworkBytesOutPerSec: Double?
    let totalNetworkCumulative: UInt64
    let hasOffender: Bool

    var isMultiProcess: Bool { members.count > 1 }

    var totalNetworkRate: Double {
        (totalNetworkBytesInPerSec ?? 0) + (totalNetworkBytesOutPerSec ?? 0)
    }
}

struct ProcessSnapshot: Sendable, Equatable {
    var processes: [ProcessEntry]
    var offenders: [ProcessOffender]
    var nettopAvailable: Bool
    var anyEstimatedEnergy: Bool
    var capturedAt: Date

    static let empty = ProcessSnapshot(
        processes: [],
        offenders: [],
        nettopAvailable: true,
        anyEstimatedEnergy: false,
        capturedAt: .distantPast
    )
}

// MARK: - Actions

enum ProcessActionKind: Sendable, Equatable {
    case quit
    case forceQuit
    case relaunchFinder

    var title: String {
        switch self {
        case .quit: "Quit Process"
        case .forceQuit: "Force Quit Process"
        case .relaunchFinder: "Relaunch Finder"
        }
    }

    var confirmButtonLabel: String {
        switch self {
        case .quit: "Quit"
        case .forceQuit: "Force Quit"
        case .relaunchFinder: "Relaunch Finder"
        }
    }
}

struct PendingProcessAction: Identifiable, Sendable, Equatable {
    let id = UUID()
    let entry: ProcessEntry
    let kind: ProcessActionKind
}

enum ProcessActionResult: Sendable, Equatable {
    case succeeded(String)
    case blocked(String)
    case failed(String)

    var message: String {
        switch self {
        case .succeeded(let text), .blocked(let text), .failed(let text): text
        }
    }

    var isError: Bool {
        if case .succeeded = self { return false }
        return true
    }
}

#if DEBUG
extension ProcessSnapshot {
    static let preview = ProcessSnapshot(
        processes: [
            ProcessEntry(
                pid: 4120,
                name: "Xcode",
                executableName: "Xcode",
                executablePath: "/Applications/Xcode.app/Contents/MacOS/Xcode",
                bundleURL: nil,
                bundleIdentifier: "com.apple.dt.Xcode",
                uid: getuid(),
                isGUIApp: true,
                cpuPercent: 78.4,
                memoryBytes: 3_420_000_000,
                energy: .measuredWatts(4.2),
                networkBytesInPerSec: 120_000,
                networkBytesOutPerSec: 24_000,
                networkTotalBytesIn: 14_500_000,
                networkTotalBytesOut: 2_300_000,
                sustainedHighCPUSeconds: 92,
                policy: .allowed,
                offenderReasons: [
                    .sustainedCPU(percent: 78.4, duration: 92),
                    .highEnergy(label: "4.2 W", isEstimated: false)
                ]
            ),
            ProcessEntry(
                pid: 882,
                name: "Safari",
                executableName: "Safari",
                executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
                bundleURL: nil,
                bundleIdentifier: "com.apple.Safari",
                uid: getuid(),
                isGUIApp: true,
                cpuPercent: 14.2,
                memoryBytes: 1_120_000_000,
                energy: .measuredWatts(0.8),
                networkBytesInPerSec: 2_600_000,
                networkBytesOutPerSec: 180_000,
                networkTotalBytesIn: 184_000_000,
                networkTotalBytesOut: 12_000_000,
                sustainedHighCPUSeconds: 0,
                policy: .allowed,
                offenderReasons: [
                    .heavyNetwork(bytesPerSecond: 2_780_000)
                ]
            ),
            ProcessEntry(
                pid: 512,
                name: "Finder",
                executableName: "Finder",
                executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
                bundleURL: nil,
                bundleIdentifier: "com.apple.finder",
                uid: getuid(),
                isGUIApp: true,
                cpuPercent: 1.8,
                memoryBytes: 164_000_000,
                energy: .measuredWatts(0.1),
                networkBytesInPerSec: 0,
                networkBytesOutPerSec: 0,
                networkTotalBytesIn: 0,
                networkTotalBytesOut: 0,
                sustainedHighCPUSeconds: 0,
                policy: .relaunchOnly(reason: "Finder cannot be killed — relaunch only"),
                offenderReasons: []
            ),
            ProcessEntry(
                pid: 168,
                name: "WindowServer",
                executableName: "WindowServer",
                executablePath: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
                bundleURL: nil,
                bundleIdentifier: nil,
                uid: 88,
                isGUIApp: false,
                cpuPercent: 11.4,
                memoryBytes: 420_000_000,
                energy: .estimated(12),
                networkBytesInPerSec: nil,
                networkBytesOutPerSec: nil,
                networkTotalBytesIn: nil,
                networkTotalBytesOut: nil,
                sustainedHighCPUSeconds: 0,
                policy: .blocked(reason: "Protected macOS system process — cannot be quit"),
                offenderReasons: []
            )
        ],
        offenders: [
            ProcessOffender(
                pid: 4120,
                name: "Xcode",
                reasons: [
                    .sustainedCPU(percent: 78.4, duration: 92),
                    .highEnergy(label: "4.2 W", isEstimated: false)
                ]
            ),
            ProcessOffender(
                pid: 882,
                name: "Safari",
                reasons: [.heavyNetwork(bytesPerSecond: 2_780_000)]
            )
        ],
        nettopAvailable: true,
        anyEstimatedEnergy: true,
        capturedAt: .now
    )
}
#endif
