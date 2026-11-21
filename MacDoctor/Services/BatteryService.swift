//
//  MacDoctor/Services/BatteryService.swift
//  Mac Doctor
//
//  Reads the AppleSmartBattery registry entry. Macs without a battery simply
//  report unavailable. Temperature and capacity health live inside the
//  BatteryData dictionary on current Apple silicon; whole-system power draw
//  lives inside PowerTelemetryData.
//
//  These are IORegistry properties, readable without privileges, but their
//  names are not formally documented by Apple. Each one is optional and is
//  sanity-checked before use.
//

import Foundation
import IOKit

actor BatteryService: BatterySampling {
    private var didLogMissing = false

    func sample() async -> BatterySample? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery"),
            &iterator
        ) == KERN_SUCCESS else {
            logMissing()
            return nil
        }
        defer { _ = IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else {
            logMissing()
            return nil
        }
        defer { _ = IOObjectRelease(service) }

        guard let percentage = IOKitProperty.number(service, "CurrentCapacity")?.intValue else {
            logMissing()
            return nil
        }

        let batteryData = IOKitProperty.value(service, "BatteryData") as? [String: Any]
        let designCapacity = (batteryData?["DesignCapacity"] as? NSNumber)?.doubleValue
        let rawMaxCapacity = (batteryData?["AppleRawMaxCapacity"] as? NSNumber)?.doubleValue
        let temperature = (batteryData?["Temperature"] as? NSNumber)?.doubleValue

        let health: Double? = {
            guard let designCapacity, designCapacity > 0, let rawMaxCapacity else {
                return nil
            }
            return min(max(rawMaxCapacity / designCapacity, 0), 1)
        }()

        // AppleSmartBattery reports centi-degrees Celsius on this hardware.
        let celsius: Double? = {
            guard let temperature else { return nil }
            let value = temperature / 100
            guard value > -20, value < 120 else { return nil }
            return value
        }()

        let remaining = IOKitProperty.number(service, "TimeRemaining")?.intValue
        let minutesRemaining = remaining.flatMap { $0 > 0 && $0 < 65_535 ? $0 : nil }
        let isPluggedIn = IOKitProperty.number(service, "ExternalConnected")?.boolValue ?? false

        let adapterDetails = IOKitProperty.value(service, "AdapterDetails") as? [String: Any]
        let rawAdapterWatts = (adapterDetails?["Watts"] as? NSNumber)?.intValue
        let adapterWatts = (isPluggedIn && (rawAdapterWatts ?? 0) > 0) ? rawAdapterWatts : nil

        let batteryNetWatts: Double? = {
            guard let millivolts = IOKitProperty.number(service, "Voltage")?.doubleValue,
                  let milliamps = (IOKitProperty.number(service, "InstantAmperage")
                      ?? IOKitProperty.number(service, "Amperage"))?.int64Value
            else {
                return nil
            }
            let watts = millivolts * Double(milliamps) / 1_000_000
            return abs(watts) < 300 ? watts : nil
        }()

        return BatterySample(
            percentage: min(max(percentage, 0), 100),
            isCharging: IOKitProperty.number(service, "IsCharging")?.boolValue ?? false,
            isPluggedIn: isPluggedIn,
            minutesRemaining: minutesRemaining,
            cycleCount: IOKitProperty.number(service, "CycleCount")?.intValue,
            health: health,
            temperatureCelsius: celsius,
            powerWatts: powerDraw(service),
            adapterWatts: adapterWatts,
            batteryNetWatts: batteryNetWatts
        )
    }

    /// Whole-system power draw in watts.
    ///
    /// 1. `PowerTelemetryData.SystemLoad` (milliwatts) is what the power
    ///    controller reports as total system consumption, on AC or battery.
    /// 2. Fallback while discharging: battery `Voltage` (mV) × `Amperage`
    ///    (mA, negative when discharging). On AC this would be the battery
    ///    charge rate, not system draw, so it is not used there.
    private func powerDraw(_ service: io_object_t) -> Double? {
        let telemetry = IOKitProperty.value(service, "PowerTelemetryData") as? [String: Any]
        if let milliwatts = (telemetry?["SystemLoad"] as? NSNumber)?.doubleValue,
           milliwatts > 0, milliwatts < 300_000 {
            return milliwatts / 1_000
        }

        guard
            let millivolts = IOKitProperty.number(service, "Voltage")?.doubleValue,
            let milliamps = (IOKitProperty.number(service, "InstantAmperage")
                ?? IOKitProperty.number(service, "Amperage"))?.int64Value,
            milliamps < 0
        else {
            return nil
        }

        let watts = millivolts * Double(-milliamps) / 1_000_000
        return watts > 0 && watts < 300 ? watts : nil
    }

    private func logMissing() {
        guard !didLogMissing else { return }
        AppLog.sensors.notice("No AppleSmartBattery service found")
        didLogMissing = true
    }
}
