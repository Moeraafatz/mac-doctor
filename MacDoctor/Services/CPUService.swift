//
//  CPUService.swift
//  Mac Doctor
//
//  Per-core CPU tick deltas from host_processor_info. The P/E split uses the
//  real device-tree cluster map when it is available; otherwise total CPU is
//  still reported and the split degrades to "—".
//

import Darwin
import Foundation

actor CPUService: CPUSampling {
    private struct Ticks: Sendable {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32

        var busy: UInt32 { user &+ system &+ nice }
        var total: UInt32 { busy &+ idle }
    }

    private var previousTicks: [Ticks]?
    private let topology: CPUTopology
    private let brand: String?
    private var didLogReadFailure = false

    init() {
        topology = CPUTopologyReader.read()
        brand = Sysctl.string("machdep.cpu.brand_string")
    }

    func sample() async -> CPUSample {
        let current = Self.readTicks()
        guard !current.isEmpty else {
            if !didLogReadFailure {
                AppLog.sensors.error("host_processor_info returned no CPU ticks")
                didLogReadFailure = true
            }
            return CPUSample(
                performanceCoreCount: topology.performanceCount,
                efficiencyCoreCount: topology.efficiencyCount,
                brand: brand
            )
        }

        let previous = previousTicks
        previousTicks = current

        guard let previous, previous.count == current.count else {
            return CPUSample(
                performanceCoreCount: topology.performanceCount,
                efficiencyCoreCount: topology.efficiencyCount,
                brand: brand
            )
        }

        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)

        var totalBusy: UInt64 = 0
        var totalTicks: UInt64 = 0
        var performanceBusy: UInt64 = 0
        var performanceTicks: UInt64 = 0
        var efficiencyBusy: UInt64 = 0
        var efficiencyTicks: UInt64 = 0

        for index in current.indices {
            let busy = UInt64(current[index].busy &- previous[index].busy)
            let ticks = UInt64(current[index].total &- previous[index].total)
            let usage = ticks == 0 ? 0 : min(max(Double(busy) / Double(ticks), 0), 1)

            perCore.append(usage)
            totalBusy += busy
            totalTicks += ticks

            if topology.performanceCores.contains(index) {
                performanceBusy += busy
                performanceTicks += ticks
            } else if topology.efficiencyCores.contains(index) {
                efficiencyBusy += busy
                efficiencyTicks += ticks
            }
        }

        let totalUsage = totalTicks == 0
            ? nil
            : min(max(Double(totalBusy) / Double(totalTicks), 0), 1)

        let performanceUsage = performanceTicks == 0
            ? nil
            : min(max(Double(performanceBusy) / Double(performanceTicks), 0), 1)

        let efficiencyUsage = efficiencyTicks == 0
            ? nil
            : min(max(Double(efficiencyBusy) / Double(efficiencyTicks), 0), 1)

        return CPUSample(
            totalUsage: totalUsage,
            performanceUsage: performanceUsage,
            efficiencyUsage: efficiencyUsage,
            performanceCoreCount: topology.performanceCount,
            efficiencyCoreCount: topology.efficiencyCount,
            perCoreUsage: perCore,
            brand: brand
        )
    }

    // MARK: - Mach ticks

    private static func readTicks() -> [Ticks] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &count,
            &info,
            &infoCount
        )

        guard result == KERN_SUCCESS, let info else {
            return []
        }

        defer {
            _ = vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            )
        }

        return info.withMemoryRebound(
            to: processor_cpu_load_info_data_t.self,
            capacity: Int(count)
        ) { load in
            (0..<Int(count)).map { index in
                let ticks = load[index].cpu_ticks
                return withUnsafePointer(to: ticks) {
                    $0.withMemoryRebound(to: UInt32.self, capacity: 4) { values in
                        Ticks(
                            user: values[Int(CPU_STATE_USER)],
                            system: values[Int(CPU_STATE_SYSTEM)],
                            idle: values[Int(CPU_STATE_IDLE)],
                            nice: values[Int(CPU_STATE_NICE)]
                        )
                    }
                }
            }
        }
    }
}
