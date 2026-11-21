//
//  MemoryService.swift
//  Mac Doctor
//
//  "Used" here means physically resident work: active + wired + compressed.
//  Inactive file cache is deliberately excluded so the number reflects
//  pressure rather than everything macOS has cached.
//

import Darwin
import Foundation

actor MemoryService: MemorySampling {
    private var didLogFailure = false

    func sample() async -> MemorySample? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            if !didLogFailure {
                AppLog.sensors.error("host_statistics64 failed: \(result)")
                didLogFailure = true
            }
            return nil
        }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else {
            if !didLogFailure {
                AppLog.sensors.error("host_page_size failed")
                didLogFailure = true
            }
            return nil
        }

        let page = Double(pageSize)
        let active = Double(statistics.active_count) * page
        let wired = Double(statistics.wire_count) * page
        let compressed = Double(statistics.compressor_page_count) * page
        let total = ProcessInfo.processInfo.physicalMemory
        let used = min(total, UInt64((active + wired + compressed).rounded()))

        let swap = Sysctl.swap()
        let pressure = MemoryPressure(level: Sysctl.int32("kern.memorystatus_vm_pressure_level"))

        return MemorySample(
            totalBytes: total,
            usedBytes: used,
            swapUsedBytes: swap?.used,
            swapTotalBytes: swap?.total,
            pressure: pressure
        )
    }
}
