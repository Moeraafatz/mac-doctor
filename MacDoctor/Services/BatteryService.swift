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
    private var cachedService: io_service_t = 0
    private var didLogMissing = false

    deinit {
        if cachedService != 0 {
            _ = IOObjectRelease(cachedService)
        }
    }

    func sample() async -> BatterySample? {
        if cachedService == 0 {
            resolveService()
        }
        guard cachedService != 0 else {
            logMissing()
            return nil
        }

        var props = IOKitProperty.allProperties(cachedService)
        if props == nil {
            _ = IOObjectRelease(cachedService)
            cachedService = 0
            resolveService()
            guard cachedService != 0 else {
                logMissing()
                return nil
            }
            props = IOKitProperty.allProperties(cachedService)
        }

        guard let props,
              let percentage = (props["CurrentCapacity"] as? NSNumber)?.intValue
        else {
            logMissing()
            return nil
        }

        let batteryData = props["BatteryData"] as? [String: Any]
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

        let remaining = (props["TimeRemaining"] as? NSNumber)?.intValue
        let minutesRemaining = remaining.flatMap { $0 > 0 && $0 < 65_535 ? $0 : nil }
        let isPluggedIn = (props["ExternalConnected"] as? NSNumber)?.boolValue ?? false

        let adapterDetails = props["AdapterDetails"] as? [String: Any]
        let rawAdapterWatts = (adapterDetails?["Watts"] as? NSNumber)?.intValue
        let adapterWatts = (isPluggedIn && (rawAdapterWatts ?? 0) > 0) ? rawAdapterWatts : nil

        let millivolts = (props["Voltage"] as? NSNumber)?.doubleValue
        let milliamps = ((props["InstantAmperage"] as? NSNumber) ?? (props["Amperage"] as? NSNumber))?.int64Value

        let batteryNetWatts: Double? = {
            guard let millivolts, let milliamps else { return nil }
            let watts = millivolts * Double(milliamps) / 1_000_000
            return abs(watts) < 300 ? watts : nil
        }()

        return BatterySample(
            percentage: min(max(percentage, 0), 100),
            isCharging: (props["IsCharging"] as? NSNumber)?.boolValue ?? false,
            isPluggedIn: isPluggedIn,
            minutesRemaining: minutesRemaining,
            cycleCount: (props["CycleCount"] as? NSNumber)?.intValue,
            health: health,
            temperatureCelsius: celsius,
            powerWatts: powerDraw(props: props, millivolts: millivolts, milliamps: milliamps),
            adapterWatts: adapterWatts,
            batteryNetWatts: batteryNetWatts
        )
    }

    private func resolveService() {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        if service != 0 {
            cachedService = service
        }
    }

    /// Whole-system power draw in watts.
    private func powerDraw(props: [String: Any], millivolts: Double?, milliamps: Int64?) -> Double? {
        let telemetry = props["PowerTelemetryData"] as? [String: Any]
        if let milliwatts = (telemetry?["SystemLoad"] as? NSNumber)?.doubleValue,
           milliwatts > 0, milliwatts < 300_000 {
            return milliwatts / 1_000
        }

        guard let millivolts, let milliamps, milliamps < 0 else {
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
