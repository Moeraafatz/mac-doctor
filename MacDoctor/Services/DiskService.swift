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
    private var didLogMissing = false

    func sample() async -> DiskSample? {
        let capacity = readCapacity()
        let counters = readCounters()
        let uptime = ProcessInfo.processInfo.systemUptime

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

    private func readCapacity() -> (total: UInt64, free: UInt64)? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [
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

    // MARK: - Throughput

    private func readCounters() -> (name: String, read: UInt64, write: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        ) == KERN_SUCCESS else {
            return nil
        }
        defer { _ = IOObjectRelease(iterator) }

        var best: (name: String, read: UInt64, write: UInt64, size: UInt64)?

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { _ = IOObjectRelease(service) }

            guard let statistics = IOKitProperty.value(service, "Statistics") as? [String: Any] else {
                continue
            }

            let read = (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            let write = (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0

            // The driver itself has no BSD name; its whole-disk media child
            // does. Pick the largest whole disk so disk images and small
            // synthetic media cannot win.
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

            let reading = (
                name: name ?? "disk",
                read: read,
                write: write,
                size: size
            )

            if let currentBest = best, reading.size <= currentBest.size {
                continue
            }
            best = reading
        }

        guard let best else { return nil }
        return (best.name, best.read, best.write)
    }
}
