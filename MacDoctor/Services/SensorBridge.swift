//
//  MacDoctor/Services/SensorBridge.swift
//  Mac Doctor
//
//  ⚠️ PRIVATE / UNDOCUMENTED API — THIS IS THE ONLY FILE THAT USES ANY.
//
//  Apple silicon has no public temperature API. Like open-source monitors
//  such as "Stats", Mac Doctor reads sensors from two undocumented sources:
//
//  1. IOHIDEventSystemClient (IOKit, private symbols)
//     Thermal sensors are HID services on the vendor usage page 0xFF00,
//     usage 0x0005. Each service returns an IOHIDEvent of type
//     kIOHIDEventTypeTemperature (15). The temperature is read with
//     IOHIDEventGetFloatValue using field (15 << 16). Names seen on an M4:
//     "PMU tdie1…14", "PMU2 tdie1…10", "gas gauge battery", "NAND CH0 temp".
//
//  2. AppleSMC user client (IOKit, undocumented struct protocol)
//     IOServiceOpen("AppleSMC") + IOConnectCallStructMethod(selector 2) with
//     the 80-byte SMCKeyData struct. Temperature keys start with "T" and use
//     the "flt " (little-endian Float32) or "sp78" (signed 8.8 fixed) types.
//
//  Safety rules followed here:
//  • Every private symbol is resolved at runtime with dlsym. If Apple removes
//    or renames one, the bridge reports "unavailable" instead of crashing.
//  • The bridge is read-only. It never writes SMC keys.
//  • No root, no entitlements, no helper. Works with Hardened Runtime and
//    App Sandbox OFF (the AppleSMC user client is not reachable from the
//    sandbox).
//  • Implausible values (NaN, ≤ 0 °C, > 125 °C) are dropped, never shown.
//
//  This class is not thread-safe. It is owned and used exclusively by the
//  TemperatureService actor.
//

import Darwin
import Foundation
import IOKit

struct RawHIDSensor: Sendable, Equatable {
    var name: String
    var celsius: Double
}

final class SensorBridge {
    private let hid: HIDTemperatureReader?
    private let smc: SMCReader?

    init() {
        hid = HIDTemperatureReader()
        smc = SMCReader()

        if hid == nil {
            AppLog.sensors.error("SensorBridge: HID temperature client unavailable")
        }
        if smc == nil {
            AppLog.sensors.error("SensorBridge: AppleSMC user client unavailable")
        }
    }

    var isHIDAvailable: Bool { hid != nil }
    var isSMCAvailable: Bool { smc != nil }

    /// Every plausible HID temperature reading. Names may repeat (for
    /// example several "gas gauge battery" services).
    func readHIDSensors() -> [RawHIDSensor] {
        hid?.read() ?? []
    }

    /// Reads the given SMC keys. Keys that do not exist, have an unsupported
    /// type, or return an implausible value are omitted from the result.
    func readSMC(keys: [String]) -> [String: Double] {
        guard let smc else { return [:] }
        var result: [String: Double] = [:]
        for key in keys {
            if let value = smc.readTemperature(key) {
                result[key] = value
            }
        }
        return result
    }

    /// Enumerates all SMC keys once and returns the temperature keys that
    /// start with one of the given prefixes. This is comparatively slow
    /// (≈2,000 IOKit calls) and should run at most once per launch.
    func discoverSMCTemperatureKeys(prefixes: [String]) -> [String] {
        smc?.discoverTemperatureKeys(prefixes: prefixes) ?? []
    }

    static func isPlausible(_ celsius: Double) -> Bool {
        celsius.isFinite && celsius > 0 && celsius <= 125
    }
}

// MARK: - IOHIDEventSystemClient (private)

/// Function signatures of the private IOKit HID symbols. CF objects are
/// passed as AnyObject; returned objects follow the CF "Create/Copy" rule
/// and are therefore taken as retained.
private typealias HIDClientCreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
private typealias HIDClientSetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Void
private typealias HIDClientCopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
private typealias HIDServiceCopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
private typealias HIDServiceCopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
private typealias HIDEventGetFloatValueFn = @convention(c) (AnyObject, Int32) -> Double

private enum IOKitSymbols {
    /// IOKit is always loaded in an AppKit process; dlopen just returns the
    /// existing handle. The handle is intentionally never closed.
    /// Written once at first access (Swift statics are lazily initialised
    /// with dispatch_once semantics) and only read afterwards.
    nonisolated(unsafe) static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/Frameworks/IOKit.framework/IOKit",
        RTLD_NOW | RTLD_NOLOAD
    ) ?? dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

    static func resolve<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else {
            AppLog.sensors.error("SensorBridge: symbol \(name, privacy: .public) not found")
            return nil
        }
        return unsafeBitCast(pointer, to: type)
    }
}

private final class HIDTemperatureReader {
    // HID constants (from IOHIDEventTypes.h / AppleHIDUsageTables.h, not in the public SDK).
    private static let vendorUsagePage = 0xFF00
    private static let temperatureSensorUsage = 0x0005
    private static let temperatureEventType: Int64 = 15            // kIOHIDEventTypeTemperature
    private static let temperatureLevelField: Int32 = 15 << 16     // kIOHIDEventFieldTemperatureLevel

    /// Rebuild the cached service list every N reads in case sensors
    /// appear or disappear (for example after sleep).
    private static let serviceRefreshInterval = 150

    private let client: AnyObject
    private let copyServices: HIDClientCopyServicesFn
    private let copyProperty: HIDServiceCopyPropertyFn
    private let copyEvent: HIDServiceCopyEventFn
    private let getFloatValue: HIDEventGetFloatValueFn

    private var services: [(name: String, service: AnyObject)] = []
    private var readsSinceRefresh = 0

    init?() {
        guard
            let create = IOKitSymbols.resolve("IOHIDEventSystemClientCreate", as: HIDClientCreateFn.self),
            let setMatching = IOKitSymbols.resolve("IOHIDEventSystemClientSetMatching", as: HIDClientSetMatchingFn.self),
            let copyServices = IOKitSymbols.resolve("IOHIDEventSystemClientCopyServices", as: HIDClientCopyServicesFn.self),
            let copyProperty = IOKitSymbols.resolve("IOHIDServiceClientCopyProperty", as: HIDServiceCopyPropertyFn.self),
            let copyEvent = IOKitSymbols.resolve("IOHIDServiceClientCopyEvent", as: HIDServiceCopyEventFn.self),
            let getFloatValue = IOKitSymbols.resolve("IOHIDEventGetFloatValue", as: HIDEventGetFloatValueFn.self),
            let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else {
            return nil
        }

        let matching: [String: Int] = [
            "PrimaryUsagePage": Self.vendorUsagePage,
            "PrimaryUsage": Self.temperatureSensorUsage
        ]
        setMatching(client, matching as CFDictionary)

        self.client = client
        self.copyServices = copyServices
        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.getFloatValue = getFloatValue
    }

    func read() -> [RawHIDSensor] {
        if services.isEmpty || readsSinceRefresh >= Self.serviceRefreshInterval {
            refreshServices()
        }
        readsSinceRefresh += 1

        var readings: [RawHIDSensor] = []
        readings.reserveCapacity(services.count)

        for entry in services {
            guard let event = copyEvent(entry.service, Self.temperatureEventType, 0, 0)?.takeRetainedValue() else {
                continue
            }
            let celsius = getFloatValue(event, Self.temperatureLevelField)
            guard SensorBridge.isPlausible(celsius) else { continue }
            readings.append(RawHIDSensor(name: entry.name, celsius: celsius))
        }

        return readings
    }

    private func refreshServices() {
        readsSinceRefresh = 0
        guard let array = copyServices(client)?.takeRetainedValue() as? [AnyObject] else {
            services = []
            AppLog.sensors.notice("SensorBridge: HID returned no temperature services")
            return
        }

        services = array.compactMap { service in
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String else {
                return nil
            }
            return (name, service)
        }
    }
}

// MARK: - AppleSMC user client (undocumented)

/// Mirrors the C layout of the SMC kernel extension's SMCKeyData_t
/// (80 bytes). Explicit padding fields reproduce C struct padding that Swift
/// would otherwise pack differently.
private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPowerLimit {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    var padding0: UInt8 = 0
    var padding1: UInt8 = 0
    var padding2: UInt8 = 0
}

private struct SMCKeyData {
    var key: UInt32 = 0
    var version = SMCVersion()
    var powerLimit = SMCPowerLimit()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
}

private final class SMCReader {
    private static let kernelIndex: UInt32 = 2          // KERNEL_INDEX_SMC
    private static let commandReadBytes: UInt8 = 5      // SMC_CMD_READ_BYTES
    private static let commandReadIndex: UInt8 = 8      // SMC_CMD_READ_INDEX
    private static let commandReadKeyInfo: UInt8 = 9    // SMC_CMD_READ_KEYINFO

    private static let typeFloat = fourCharCode("flt ")
    private static let typeSP78 = fourCharCode("sp78")

    private var connection: io_connect_t = 0
    private var keyInfoCache: [UInt32: SMCKeyInfo] = [:]
    private var missingKeys: Set<UInt32> = []

    init?() {
        guard MemoryLayout<SMCKeyData>.size == 80 else {
            AppLog.sensors.fault("SensorBridge: SMCKeyData layout mismatch; SMC disabled")
            return nil
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { _ = IOObjectRelease(service) }

        var connection: io_connect_t = 0
        let status = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard status == KERN_SUCCESS, connection != 0 else {
            AppLog.sensors.error("SensorBridge: IOServiceOpen(AppleSMC) failed: \(status, privacy: .public)")
            return nil
        }
        self.connection = connection
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func readTemperature(_ key: String) -> Double? {
        let code = Self.fourCharCode(key)
        guard !missingKeys.contains(code) else { return nil }

        guard let info = keyInfo(for: code) else {
            missingKeys.insert(code)
            return nil
        }

        guard info.dataType == Self.typeFloat || info.dataType == Self.typeSP78 else {
            missingKeys.insert(code)
            return nil
        }

        var input = SMCKeyData()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.command = Self.commandReadBytes

        guard let output = call(&input) else { return nil }

        var raw = output.bytes
        let dataSize = Int(min(info.dataSize, 32))
        let celsius: Double? = withUnsafeBytes(of: &raw) { buf in
            if info.dataType == Self.typeFloat, dataSize >= 4 {
                // Apple silicon stores "flt " in native (little-endian) order.
                let bits = UInt32(buf[0])
                    | UInt32(buf[1]) << 8
                    | UInt32(buf[2]) << 16
                    | UInt32(buf[3]) << 24
                return Double(Float(bitPattern: bits))
            } else if info.dataType == Self.typeSP78, dataSize >= 2 {
                // Signed 8.8 fixed point, big-endian.
                let value = Int16(bitPattern: UInt16(buf[0]) << 8 | UInt16(buf[1]))
                return Double(value) / 256
            }
            return nil
        }

        guard let celsius else { return nil }
        return SensorBridge.isPlausible(celsius) ? celsius : nil
    }

    func discoverTemperatureKeys(prefixes: [String]) -> [String] {
        guard let count = keyCount(), count > 0 else { return [] }

        var keys: [String] = []
        for index in 0..<count {
            var input = SMCKeyData()
            input.command = Self.commandReadIndex
            input.data32 = UInt32(index)

            guard let output = call(&input) else { continue }
            let name = Self.string(from: output.key)
            guard prefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            guard let info = keyInfo(for: output.key),
                  info.dataType == Self.typeFloat || info.dataType == Self.typeSP78
            else {
                continue
            }
            keys.append(name)
        }

        AppLog.sensors.info("SensorBridge: discovered \(keys.count, privacy: .public) SMC temperature keys")
        return keys.sorted()
    }

    // MARK: Private

    private func keyCount() -> Int? {
        let code = Self.fourCharCode("#KEY")
        guard let info = keyInfo(for: code) else { return nil }

        var input = SMCKeyData()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.command = Self.commandReadBytes

        guard let output = call(&input) else { return nil }
        var raw = output.bytes
        let bytes = withUnsafeBytes(of: &raw) { Array($0.prefix(4)) }
        // "#KEY" is a big-endian ui32.
        return Int(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }

    private func keyInfo(for code: UInt32) -> SMCKeyInfo? {
        if let cached = keyInfoCache[code] { return cached }

        var input = SMCKeyData()
        input.key = code
        input.command = Self.commandReadKeyInfo

        guard let output = call(&input), output.keyInfo.dataSize > 0 else { return nil }
        keyInfoCache[code] = output.keyInfo
        return output.keyInfo
    }

    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride

        let status = IOConnectCallStructMethod(
            connection,
            Self.kernelIndex,
            &input,
            MemoryLayout<SMCKeyData>.stride,
            &output,
            &outputSize
        )

        guard status == KERN_SUCCESS, output.result == 0 else { return nil }
        return output
    }

    private static func fourCharCode(_ string: String) -> UInt32 {
        string.utf8.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    private static func string(from code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
