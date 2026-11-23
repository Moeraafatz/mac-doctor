//
//  DiskService.swift
//  Mac Doctor
//
//  Capacity comes from the home volume's resource values (APFS container
//  aware). Throughput is a delta of IOBlockStorageDriver byte counters, so
//  the first sample reports capacity only.
//

import Foundation
import IOKit

actor DiskService: DiskSampling {
    private var previousCounters: (read: UInt64, write: UInt64)?
    private var previousUptime: TimeInterval?
    private var cachedCapacity: (total: UInt64, free: UInt64, uptime: TimeInterval)?
    private var cachedDriverService: io_service_t = 0
    private var cachedDeviceName: String = "disk"
    private var didLogMissing = false

    private let homeURL = URL(fileURLWithPath: NSHomeDirectory())
    private static let capacityCacheTTL: TimeInterval = 10

    deinit {
        if cachedDriverService != 0 {
            _ = IOObjectRelease(cachedDriverService)
        }
    }

    func sample() async -> DiskSample? {
        let uptime = ProcessInfo.processInfo.systemUptime
        let capacity = readCapacityCached(at: uptime)
        let counters = readCountersCached()

        var readRate: Double?
        var writeRate: Double?

        if let counters, let previousCounters, let previousUptime {
            let elapsed = max(uptime - previousUptime, 0.1)
            readRate = Double(counters.read &- previousCounters.read) / elapsed
            writeRate = Double(counters.write &- previousCounters.write) / elapsed
        }

        if let counters {
            previousCounters = (counters.read, counters.write)
            previousUptime = uptime
        }

        guard capacity != nil || counters != nil else {
            if !didLogMissing {
                AppLog.sensors.error("Disk capacity and IO counters unavailable")
                didLogMissing = true
            }
            return nil
        }

        return DiskSample(
            totalBytes: capacity?.total,
            freeBytes: capacity?.free,
            readBytesPerSecond: readRate,
            writeBytesPerSecond: writeRate,
            deviceName: counters?.name
        )
    }

    // MARK: - Capacity

    private func readCapacityCached(at uptime: TimeInterval) -> (total: UInt64, free: UInt64)? {
        if let cachedCapacity, (uptime - cachedCapacity.uptime) < Self.capacityCacheTTL {
            return (cachedCapacity.total, cachedCapacity.free)
        }
        guard let fresh = readCapacity() else { return cachedCapacity.map { ($0.total, $0.free) } }
        cachedCapacity = (fresh.total, fresh.free, uptime)
        return fresh
    }

    private func readCapacity() -> (total: UInt64, free: UInt64)? {
        guard let values = try? homeURL.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey
        ]),
        let total = values.volumeTotalCapacity,
        let free = values.volumeAvailableCapacity,
        total > 0,
        free >= 0
        else {
            return nil
        }

        return (UInt64(total), UInt64(free))
    }

    // MARK: - Throughput (cached IOBlockStorageDriver handle)

    private func readCountersCached() -> (name: String, read: UInt64, write: UInt64)? {
        if cachedDriverService == 0 {
            resolvePrimaryDriver()
        }
        if cachedDriverService != 0,
           let statistics = IOKitProperty.value(cachedDriverService, "Statistics") as? [String: Any] {
            let read = (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            let write = (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            return (cachedDeviceName, read, write)
        }

        // Re-resolve once if handle became stale.
        if cachedDriverService != 0 {
            _ = IOObjectRelease(cachedDriverService)
            cachedDriverService = 0
        }
        resolvePrimaryDriver()
        guard cachedDriverService != 0,
              let statistics = IOKitProperty.value(cachedDriverService, "Statistics") as? [String: Any]
        else {
            return nil
        }
        let read = (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
        let write = (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        return (cachedDeviceName, read, write)
    }

    private func resolvePrimaryDriver() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        ) == KERN_SUCCESS else {
            return
        }
        defer { _ = IOObjectRelease(iterator) }

        var bestService: io_service_t = 0
        var bestName = "disk"
        var bestSize: UInt64 = 0

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }

            guard IOKitProperty.value(service, "Statistics") != nil else {
                _ = IOObjectRelease(service)
                continue
            }

            var name: String?
            var size: UInt64 = 0
            var childIterator: io_iterator_t = 0

            if IORegistryEntryGetChildIterator(
                service,
                kIOServicePlane,
                &childIterator
            ) == KERN_SUCCESS {
                defer { _ = IOObjectRelease(childIterator) }

                while true {
                    let child = IOIteratorNext(childIterator)
                    if child == 0 { break }
                    defer { _ = IOObjectRelease(child) }

                    guard IOKitProperty.number(child, "Whole")?.boolValue == true,
                          let childName = IOKitProperty.string(child, "BSD Name"),
                          childName.hasPrefix("disk")
                    else {
                        continue
                    }

                    let childSize = IOKitProperty.number(child, "Size")?.uint64Value ?? 0
                    if childSize >= size {
                        name = childName
                        size = childSize
                    }
                }
            }

            if bestService == 0 || size > bestSize {
                if bestService != 0 {
                    _ = IOObjectRelease(bestService)
                }
                bestService = service
                bestName = name ?? "disk"
                bestSize = size
            } else {
                _ = IOObjectRelease(service)
            }
        }

        cachedDriverService = bestService
        cachedDeviceName = bestName
    }
}
