//
//  MacDoctor/Models/SystemMetrics.swift
//  Mac Doctor
//
//  Immutable, Sendable readings produced by the sampling services. Every
//  field that can legitimately be absent is optional; the UI renders an
//  explicit unavailable state instead of inventing a value.
//

import Foundation

struct SystemSnapshot: Sendable, Equatable {
    var cpu: CPUSample?
    var gpu: GPUSample?
    var memory: MemorySample?
    var disk: DiskSample?
    var battery: BatterySample?
    var thermal: ThermalSample?
    var network: NetworkSample?
    var temperatures: TemperatureSample?
    var sleepBlockers: [SleepBlocker]
    var capturedAt: Date

    init(
        cpu: CPUSample? = nil,
        gpu: GPUSample? = nil,
        memory: MemorySample? = nil,
        disk: DiskSample? = nil,
        battery: BatterySample? = nil,
        thermal: ThermalSample? = nil,
        network: NetworkSample? = nil,
        temperatures: TemperatureSample? = nil,
        sleepBlockers: [SleepBlocker] = [],
        capturedAt: Date = .now
    ) {
        self.cpu = cpu
        self.gpu = gpu
        self.memory = memory
        self.disk = disk
        self.battery = battery
        self.thermal = thermal
        self.network = network
        self.temperatures = temperatures
        self.sleepBlockers = sleepBlockers
        self.capturedAt = capturedAt
    }

    static let empty = SystemSnapshot(capturedAt: .distantPast)

    var hasReadings: Bool {
        cpu != nil
            || gpu != nil
            || memory != nil
            || disk != nil
            || battery != nil
            || thermal != nil
            || network != nil
            || temperatures != nil
    }
}

// MARK: - CPU

struct CPUSample: Sendable, Equatable {
    /// Fraction of all cores busy, 0...1. Nil until a second tick sample
    /// establishes a delta.
    var totalUsage: Double?
    var performanceUsage: Double?
    var efficiencyUsage: Double?
    var performanceCoreCount: Int
    var efficiencyCoreCount: Int
    var perCoreUsage: [Double]
    var brand: String?

    init(
        totalUsage: Double? = nil,
        performanceUsage: Double? = nil,
        efficiencyUsage: Double? = nil,
        performanceCoreCount: Int = 0,
        efficiencyCoreCount: Int = 0,
        perCoreUsage: [Double] = [],
        brand: String? = nil
    ) {
        self.totalUsage = totalUsage
        self.performanceUsage = performanceUsage
        self.efficiencyUsage = efficiencyUsage
        self.performanceCoreCount = performanceCoreCount
        self.efficiencyCoreCount = efficiencyCoreCount
        self.perCoreUsage = perCoreUsage
        self.brand = brand
    }

    var hasClusterSplit: Bool {
        performanceCoreCount > 0
            && efficiencyCoreCount > 0
            && performanceUsage != nil
            && efficiencyUsage != nil
    }
}

// MARK: - GPU

struct GPUSample: Sendable, Equatable {
    /// Fraction of the GPU busy, 0...1.
    var utilization: Double?
    var coreCount: Int?
    var model: String?
}

// MARK: - Memory

enum MemoryPressure: String, Sendable, Equatable {
    case normal
    case warning
    case critical
    case unknown

    var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        case .unknown: "Unknown"
        }
    }

    init(level: Int32?) {
        guard let level else {
            self = .unknown
            return
        }

        if level >= 4 {
            self = .critical
        } else if level >= 2 {
            self = .warning
        } else if level == 1 {
            self = .normal
        } else {
            self = .unknown
        }
    }
}

struct MemorySample: Sendable, Equatable {
    var totalBytes: UInt64
    var usedBytes: UInt64
    var swapUsedBytes: UInt64?
    var swapTotalBytes: UInt64?
    var pressure: MemoryPressure

    var availableBytes: UInt64 {
        totalBytes > usedBytes ? totalBytes - usedBytes : 0
    }
}

// MARK: - Disk

struct DiskSample: Sendable, Equatable {
    var totalBytes: UInt64?
    var freeBytes: UInt64?
    var readBytesPerSecond: Double?
    var writeBytesPerSecond: Double?
    var deviceName: String?

    var usedFraction: Double? {
        guard let totalBytes, let freeBytes, totalBytes > 0 else { return nil }
        let used = totalBytes > freeBytes ? totalBytes - freeBytes : 0
        return Double(used) / Double(totalBytes)
    }
}

// MARK: - Battery

struct BatterySample: Sendable, Equatable {
    var percentage: Int
    var isCharging: Bool
    var isPluggedIn: Bool
    var minutesRemaining: Int?
    var cycleCount: Int?
    /// 0...1. Derived from AppleRawMaxCapacity / DesignCapacity.
    var health: Double?
    var temperatureCelsius: Double?
    /// Whole-system power draw in watts, from AppleSmartBattery
    /// PowerTelemetryData.SystemLoad; falls back to battery V × I while
    /// discharging. Nil when neither is reported.
    var powerWatts: Double?
    /// Rated wattage of the connected USB-C / MagSafe power adapter, if plugged in.
    var adapterWatts: Int?
    /// Net battery power flow in watts: positive while charging, negative while discharging.
    var batteryNetWatts: Double?
}

// MARK: - Sleep assertions

struct SleepBlocker: Identifiable, Sendable, Equatable {
    var id: pid_t { pid }
    var pid: pid_t
    var processName: String
    var reason: String
    var blocksDisplay: Bool
}

// MARK: - Thermal

enum ThermalCondition: String, Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical

    var label: String {
        switch self {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        }
    }

    var detail: String {
        switch self {
        case .nominal: "No thermal pressure"
        case .fair: "Slightly elevated"
        case .serious: "Reduce sustained load"
        case .critical: "Let the Mac cool down"
        }
    }
}

struct ThermalSample: Sendable, Equatable {
    var condition: ThermalCondition
    var lowPowerMode: Bool
}

// MARK: - Network

struct NetworkSample: Sendable, Equatable {
    var downloadBytesPerSecond: Double?
    var uploadBytesPerSecond: Double?
    var interfaceName: String?
}

// MARK: - Overall health

enum SystemHealth: Sendable, Equatable {
    case starting
    case stable
    case elevated
    case critical

    var label: String {
        switch self {
        case .starting: "Starting"
        case .stable: "Stable"
        case .elevated: "Elevated"
        case .critical: "Critical"
        }
    }
}

#if DEBUG
extension SystemSnapshot {
    /// Design-time sample used only by SwiftUI previews and the offscreen
    /// snapshot tool. Never referenced by the running application.
    static let preview = SystemSnapshot(
        cpu: CPUSample(
            totalUsage: 0.24,
            performanceUsage: 0.31,
            efficiencyUsage: 0.14,
            performanceCoreCount: 4,
            efficiencyCoreCount: 6,
            perCoreUsage: [0.18, 0.22, 0.09, 0.12, 0.10, 0.08, 0.34, 0.29, 0.41, 0.27],
            brand: "Apple M4"
        ),
        gpu: GPUSample(utilization: 0.35, coreCount: 10, model: "Apple M4"),
        memory: MemorySample(
            totalBytes: 25_769_803_776,
            usedBytes: 18_400_000_000,
            swapUsedBytes: 4_700_000_000,
            swapTotalBytes: 6_442_450_944,
            pressure: .normal
        ),
        disk: DiskSample(
            totalBytes: 494_384_795_648,
            freeBytes: 15_758_016_512,
            readBytesPerSecond: 1_240_000,
            writeBytesPerSecond: 340_000,
            deviceName: "disk0"
        ),
        battery: BatterySample(
            percentage: 76,
            isCharging: true,
            isPluggedIn: true,
            minutesRemaining: 152,
            cycleCount: 138,
            health: 0.967,
            temperatureCelsius: 38.09,
            powerWatts: 9.4
        ),
        thermal: ThermalSample(condition: .nominal, lowPowerMode: false),
        network: NetworkSample(
            downloadBytesPerSecond: 2_400_000,
            uploadBytesPerSecond: 128_000,
            interfaceName: "en0"
        ),
        temperatures: .preview,
        capturedAt: .now
    )
}
#endif
