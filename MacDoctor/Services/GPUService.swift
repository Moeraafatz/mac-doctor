//
//  GPUService.swift
//  Mac Doctor
//
//  GPU utilization comes from IOAccelerator's PerformanceStatistics. Apple
//  does not publish this as a supported API, so absence is handled as an
//  unavailable reading rather than an error.
//

import Foundation
import IOKit

actor GPUService: GPUSampling {
    private var didLogMissing = false

    func sample() async -> GPUSample? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        ) == KERN_SUCCESS else {
            logMissing()
            return nil
        }
        defer { _ = IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { _ = IOObjectRelease(service) }

            let statistics = IOKitProperty.value(service, "PerformanceStatistics") as? [String: Any]
            let utilization = (statistics?["Device Utilization %"] as? NSNumber)?.doubleValue
            let model = IOKitProperty.string(service, "model")
            let cores = IOKitProperty.number(service, "gpu-core-count")?.intValue

            if utilization != nil || model != nil {
                return GPUSample(
                    utilization: utilization.map { min(max($0 / 100, 0), 1) },
                    coreCount: cores,
                    model: model
                )
            }
        }

        logMissing()
        return nil
    }

    private func logMissing() {
        guard !didLogMissing else { return }
        AppLog.sensors.notice("No IOAccelerator utilization source found")
        didLogMissing = true
    }
}
