//
//  ServiceSupport.swift
//  Mac Doctor
//
//  Thin, read-only wrappers around sysctl and IOKit. Keeping these in one
//  place makes the services themselves small and testable.
//

import Darwin
import Foundation
import IOKit

// MARK: - sysctl

enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }

        let end = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<end], as: UTF8.self)
    }

    static func int(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return Int(value)
    }

    static func int32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return value
    }

    static func swap() -> (used: UInt64, total: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            return nil
        }
        return (usage.xsu_used, usage.xsu_total)
    }
}

// MARK: - IOKit properties

enum IOKitProperty {
    static func value(_ service: io_object_t, _ key: String) -> Any? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            return nil
        }
        return unmanaged.takeRetainedValue()
    }

    /// Handles both CFString and the NUL-terminated CFData strings used by
    /// the device tree (`"cluster-type" = <"P">`).
    static func string(_ service: io_object_t, _ key: String) -> String? {
        if let string = value(service, key) as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let data = value(service, key) as? Data {
            let trimmed = data.prefix { $0 != 0 }
            return String(decoding: trimmed, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    static func number(_ service: io_object_t, _ key: String) -> NSNumber? {
        value(service, key) as? NSNumber
    }

    /// Reads the entire property dictionary in a single IOKit kernel crossing
    /// instead of issuing 8–12 separate `IORegistryEntryCreateCFProperty` calls.
    static func allProperties(_ service: io_object_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        let status = IORegistryEntryCreateCFProperties(
            service,
            &unmanaged,
            kCFAllocatorDefault,
            0
        )
        guard status == KERN_SUCCESS, let dict = unmanaged?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return dict
    }
}

// MARK: - CPU topology

struct CPUTopology: Sendable, Equatable {
    var efficiencyCores: Set<Int>
    var performanceCores: Set<Int>
    var efficiencyCount: Int
    var performanceCount: Int

    var hasCoreMapping: Bool {
        !efficiencyCores.isEmpty && !performanceCores.isEmpty
    }
}

/// Reads the actual logical-CPU to cluster assignment from the device tree.
/// On Apple silicon the efficiency cluster is usually CPU 0...N and the
/// performance cluster is the remainder, but that ordering is an
/// implementation detail; this reads it instead of assuming it.
enum CPUTopologyReader {
    static func read() -> CPUTopology {
        let performanceCount = Sysctl.int("hw.perflevel0.logicalcpu") ?? 0
        let efficiencyCount = Sysctl.int("hw.perflevel1.logicalcpu") ?? 0

        var performance: Set<Int> = []
        var efficiency: Set<Int> = []

        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        if cpus != 0 {
            defer { _ = IOObjectRelease(cpus) }

            var iterator: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS {
                defer { _ = IOObjectRelease(iterator) }

                while true {
                    let child = IOIteratorNext(iterator)
                    if child == 0 { break }
                    defer { _ = IOObjectRelease(child) }

                    guard let id = IOKitProperty.number(child, "logical-cpu-id")?.intValue,
                          let cluster = IOKitProperty.string(child, "cluster-type")
                    else {
                        continue
                    }

                    switch cluster.uppercased() {
                    case "P": performance.insert(id)
                    case "E": efficiency.insert(id)
                    default: break
                    }
                }
            }
        }

        guard !performance.isEmpty, !efficiency.isEmpty else {
            AppLog.sensors.error("CPU cluster mapping unavailable; P/E split disabled")
            return CPUTopology(
                efficiencyCores: [],
                performanceCores: [],
                efficiencyCount: efficiencyCount,
                performanceCount: performanceCount
            )
        }

        return CPUTopology(
            efficiencyCores: efficiency,
            performanceCores: performance,
            efficiencyCount: efficiency.count,
            performanceCount: performance.count
        )
    }
}
