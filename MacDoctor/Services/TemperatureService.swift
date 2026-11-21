//
//  MacDoctor/Services/TemperatureService.swift
//  Mac Doctor
//
//  Turns raw SensorBridge readings into labelled groups. Contains no
//  private API itself; all of that lives in SensorBridge.swift.
//
//  Grouping strategy
//  • CPU P-cores / E-cores / GPU come from SMC keys. Apple does not publish
//    which key maps to which core, so sensors are labelled "Sensor 1…n",
//    never "Core n". The preferred key lists match the ones used by the
//    open-source "Stats" app for M4-class chips (verified present on a
//    MacBook Air M4, Mac16,13). If none of them exist on this Mac, the
//    service falls back to every SMC temperature key in the same family
//    (Tp*, Te*, Tg*), discovered once per launch.
//  • SoC die temps come from HID "PMU tdie*" sensors.
//  • Battery comes from HID "gas gauge battery", falling back to SMC TB*T.
//  • SSD comes from HID "NAND CH* temp".
//

import Foundation

actor TemperatureService: TemperatureSampling {
    private struct SMCFamily {
        let group: SensorGroup
        let preferredKeys: [String]
        let fallbackPrefix: String
    }

    private static let smcFamilies: [SMCFamily] = [
        SMCFamily(
            group: .performanceCores,
            preferredKeys: ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"],
            fallbackPrefix: "Tp"
        ),
        SMCFamily(
            group: .efficiencyCores,
            preferredKeys: ["Te05", "Te0S", "Te09", "Te0H"],
            fallbackPrefix: "Te"
        ),
        SMCFamily(
            group: .gpu,
            preferredKeys: ["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"],
            fallbackPrefix: "Tg"
        )
    ]

    private static let smcBatteryKeys = ["TB0T", "TB1T", "TB2T"]

    private let bridge: SensorBridge
    /// Resolved SMC keys per group. Nil until the first sample.
    private var resolvedKeys: [SensorGroup: [String]]?
    private var didLogEmpty = false

    init() {
        bridge = SensorBridge()
    }

    func sample() async -> TemperatureSample? {
        guard bridge.isHIDAvailable || bridge.isSMCAvailable else { return nil }

        let keys = resolveKeysIfNeeded()
        let allKeys = keys.values.flatMap { $0 } + Self.smcBatteryKeys
        let smcValues = bridge.readSMC(keys: allKeys)
        let hid = bridge.readHIDSensors()

        var groups: [SensorGroup: TemperatureGroupReading] = [:]

        for family in Self.smcFamilies {
            let readings = (keys[family.group] ?? []).enumerated().compactMap { offset, key -> SensorReading? in
                guard let value = smcValues[key] else { return nil }
                return SensorReading(
                    id: key,
                    label: "\(family.group.sensorNoun) \(offset + 1)",
                    celsius: value,
                    source: .smc
                )
            }
            groups[family.group] = TemperatureGroupReading(group: family.group, readings: readings)
        }

        groups[.soc] = TemperatureGroupReading(
            group: .soc,
            readings: hidReadings(hid, group: .soc) { $0.hasPrefix("PMU") && $0.contains("tdie") }
        )

        var battery = hidReadings(hid, group: .battery) { $0.localizedCaseInsensitiveContains("battery") }
        if battery.isEmpty {
            battery = Self.smcBatteryKeys.enumerated().compactMap { offset, key in
                smcValues[key].map {
                    SensorReading(id: key, label: "\(SensorGroup.battery.sensorNoun) \(offset + 1)", celsius: $0, source: .smc)
                }
            }
        }
        groups[.battery] = TemperatureGroupReading(group: .battery, readings: battery)

        groups[.ssd] = TemperatureGroupReading(
            group: .ssd,
            readings: hidReadings(hid, group: .ssd) { $0.hasPrefix("NAND") }
        )

        let sample = TemperatureSample(
            groups: groups,
            smcAvailable: bridge.isSMCAvailable,
            hidAvailable: bridge.isHIDAvailable
        )

        if !sample.hasReadings, !didLogEmpty {
            AppLog.sensors.notice("TemperatureService: no readable temperature sensors")
            didLogEmpty = true
        }

        return sample
    }

    // MARK: - Private

    private func resolveKeysIfNeeded() -> [SensorGroup: [String]] {
        if let resolvedKeys { return resolvedKeys }

        var resolved: [SensorGroup: [String]] = [:]
        var needsDiscovery: [SMCFamily] = []

        for family in Self.smcFamilies {
            let present = bridge.readSMC(keys: family.preferredKeys)
            let keys = family.preferredKeys.filter { present[$0] != nil }
            if keys.isEmpty {
                needsDiscovery.append(family)
            } else {
                resolved[family.group] = keys
            }
        }

        if !needsDiscovery.isEmpty, bridge.isSMCAvailable {
            let discovered = bridge.discoverSMCTemperatureKeys(prefixes: needsDiscovery.map(\.fallbackPrefix))
            for family in needsDiscovery {
                let keys = discovered.filter { $0.hasPrefix(family.fallbackPrefix) }
                resolved[family.group] = keys
                AppLog.sensors.info(
                    "TemperatureService: \(family.group.rawValue, privacy: .public) using \(keys.count, privacy: .public) discovered keys"
                )
            }
        }

        resolvedKeys = resolved
        return resolved
    }

    /// HID sensor names are sorted naturally ("tdie2" before "tdie10") so
    /// row labels stay stable between refreshes.
    private func hidReadings(
        _ sensors: [RawHIDSensor],
        group: SensorGroup,
        matching predicate: (String) -> Bool
    ) -> [SensorReading] {
        sensors
            .filter { predicate($0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .enumerated()
            .map { offset, sensor in
                SensorReading(
                    id: "\(sensor.name)#\(offset)",
                    label: "\(group.sensorNoun) \(offset + 1)",
                    celsius: sensor.celsius,
                    source: .hid
                )
            }
    }
}
