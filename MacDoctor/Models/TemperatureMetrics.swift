//
//  MacDoctor/Models/TemperatureMetrics.swift
//  Mac Doctor
//
//  Sendable temperature readings produced by TemperatureService. Values are
//  always real sensor readings in degrees Celsius; a group with no readable
//  sensor is simply absent so the UI can show "Unavailable".
//

import Foundation

// MARK: - Groups

enum SensorGroup: String, CaseIterable, Identifiable, Sendable {
    case performanceCores
    case efficiencyCores
    case gpu
    case soc
    case battery
    case ssd

    var id: Self { self }

    var title: String {
        switch self {
        case .performanceCores: "CPU P-cores"
        case .efficiencyCores: "CPU E-cores"
        case .gpu: "GPU"
        case .soc: "SoC die"
        case .battery: "Battery"
        case .ssd: "SSD"
        }
    }

    var symbol: String {
        switch self {
        case .performanceCores: "cpu.fill"
        case .efficiencyCores: "cpu"
        case .gpu: "rectangle.3.group"
        case .soc: "square.grid.3x3.square"
        case .battery: "battery.75percent"
        case .ssd: "internaldrive"
        }
    }

    /// Short label used for each individual sensor row inside a group.
    var sensorNoun: String {
        switch self {
        case .performanceCores, .efficiencyCores, .gpu: "Sensor"
        case .soc: "Die"
        case .battery: "Sensor"
        case .ssd: "Channel"
        }
    }
}

enum SensorSource: String, Sendable {
    case smc = "SMC"
    case hid = "HID"
}

// MARK: - Readings

struct SensorReading: Identifiable, Sendable, Equatable {
    /// Stable identifier: SMC key ("Tp01") or HID product name + index.
    var id: String
    var label: String
    var celsius: Double
    var source: SensorSource
}

struct TemperatureGroupReading: Sendable, Equatable {
    var group: SensorGroup
    var readings: [SensorReading]

    var average: Double? {
        guard !readings.isEmpty else { return nil }
        return readings.reduce(0) { $0 + $1.celsius } / Double(readings.count)
    }

    var maximum: Double? {
        readings.map(\.celsius).max()
    }

    var source: SensorSource? {
        readings.first?.source
    }
}

struct TemperatureSample: Sendable, Equatable {
    var groups: [SensorGroup: TemperatureGroupReading]
    /// False when the SMC user client could not be opened.
    var smcAvailable: Bool
    /// False when the HID event system client could not be created.
    var hidAvailable: Bool

    func reading(for group: SensorGroup) -> TemperatureGroupReading? {
        guard let reading = groups[group], !reading.readings.isEmpty else { return nil }
        return reading
    }

    /// Hottest real reading across every group.
    var hottest: (group: SensorGroup, celsius: Double)? {
        groups.values
            .compactMap { reading in reading.maximum.map { (reading.group, $0) } }
            .max { $0.1 < $1.1 }
    }

    /// Hottest CPU reading (P or E cluster). Used by the menu bar readout.
    var hottestCPU: Double? {
        [reading(for: .performanceCores)?.maximum, reading(for: .efficiencyCores)?.maximum]
            .compactMap { $0 }
            .max()
    }

    var hasReadings: Bool {
        groups.values.contains { !$0.readings.isEmpty }
    }

    static func == (lhs: TemperatureSample, rhs: TemperatureSample) -> Bool {
        lhs.groups == rhs.groups
            && lhs.smcAvailable == rhs.smcAvailable
            && lhs.hidAvailable == rhs.hidAvailable
    }
}

// MARK: - Units and preferences

enum TemperatureUnit: String, CaseIterable, Identifiable, Sendable {
    case celsius
    case fahrenheit

    var id: Self { self }

    var symbol: String {
        switch self {
        case .celsius: "°C"
        case .fahrenheit: "°F"
        }
    }

    func convert(_ celsius: Double) -> Double {
        switch self {
        case .celsius: celsius
        case .fahrenheit: celsius * 9 / 5 + 32
        }
    }

    func format(_ celsius: Double?, decimals: Int = 0) -> String {
        guard let celsius, celsius.isFinite else { return "—" }
        let value = convert(celsius)
        return String(format: "%.\(max(decimals, 0))f%@", value, symbol)
    }
}

/// UserDefaults keys shared by the Temperatures tab and (in Phase 6) the
/// Settings screen and notifications.
enum TemperaturePreferences {
    static let unitKey = "temperatureUnit"
    static let alertThresholdKey = "temperatureAlertThresholdCelsius"
    static let defaultAlertThreshold: Double = 95

    /// Warning starts this many degrees below the user's alert threshold.
    static let warningMargin: Double = 20

    static func tone(for celsius: Double?, threshold: Double) -> StatusTone {
        guard let celsius else { return .neutral }
        if celsius >= threshold { return .critical }
        if celsius >= threshold - warningMargin { return .warning }
        return .success
    }
}

#if DEBUG
extension TemperatureSample {
    static let preview = TemperatureSample(
        groups: [
            .performanceCores: TemperatureGroupReading(
                group: .performanceCores,
                readings: [59.3, 58.3, 58.4, 58.2, 59.5, 58.5, 58.8, 58.0].enumerated().map {
                    SensorReading(id: "Tp\($0.offset)", label: "Sensor \($0.offset + 1)", celsius: $0.element, source: .smc)
                }
            ),
            .efficiencyCores: TemperatureGroupReading(
                group: .efficiencyCores,
                readings: [60.4, 57.6, 60.1, 59.1].enumerated().map {
                    SensorReading(id: "Te\($0.offset)", label: "Sensor \($0.offset + 1)", celsius: $0.element, source: .smc)
                }
            ),
            .gpu: TemperatureGroupReading(
                group: .gpu,
                readings: [49.7, 54.3, 50.1, 54.7].enumerated().map {
                    SensorReading(id: "Tg\($0.offset)", label: "Sensor \($0.offset + 1)", celsius: $0.element, source: .smc)
                }
            ),
            .soc: TemperatureGroupReading(
                group: .soc,
                readings: [46.0, 45.5, 41.3].enumerated().map {
                    SensorReading(id: "tdie\($0.offset)", label: "Die \($0.offset + 1)", celsius: $0.element, source: .hid)
                }
            ),
            .battery: TemperatureGroupReading(
                group: .battery,
                readings: [SensorReading(id: "gg0", label: "Sensor 1", celsius: 35.4, source: .hid)]
            )
        ],
        smcAvailable: true,
        hidAvailable: true
    )
}
#endif
