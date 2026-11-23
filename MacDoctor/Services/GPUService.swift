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
    private var cachedService: io_service_t = 0
    private var cachedModel: String?
    private var cachedCores: Int?
    private var didLogMissing = false

    deinit {
        if cachedService != 0 {
            _ = IOObjectRelease(cachedService)
        }
    }

    func sample() async -> GPUSample? {
        if cachedService == 0 {
            resolveService()
        }
        guard cachedService != 0 else {
            logMissing()
            return nil
        }

        if let statistics = IOKitProperty.value(cachedService, "PerformanceStatistics") as? [String: Any] {
            let utilization = (statistics["Device Utilization %"] as? NSNumber)?.doubleValue
            if utilization != nil || cachedModel != nil {
                return GPUSample(
                    utilization: utilization.map { min(max($0 / 100, 0), 1) },
                    coreCount: cachedCores,
                    model: cachedModel
                )
            }
        }

        // Service handle may have gone stale (e.g. display/GPU reset); re-resolve once.
        releaseCachedService()
        resolveService()
        guard cachedService != 0 else {
            logMissing()
            return nil
        }

        let statistics = IOKitProperty.value(cachedService, "PerformanceStatistics") as? [String: Any]
        let utilization = (statistics?["Device Utilization %"] as? NSNumber)?.doubleValue
        if utilization != nil || cachedModel != nil {
            return GPUSample(
                utilization: utilization.map { min(max($0 / 100, 0), 1) },
                coreCount: cachedCores,
                model: cachedModel
            )
        }

        logMissing()
        return nil
    }

    private func resolveService() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        ) == KERN_SUCCESS else {
            return
        }
        defer { _ = IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }

            let statistics = IOKitProperty.value(service, "PerformanceStatistics") as? [String: Any]
            let model = IOKitProperty.string(service, "model")
            let cores = IOKitProperty.number(service, "gpu-core-count")?.intValue

            if statistics != nil || model != nil {
                cachedService = service
                cachedModel = model
                cachedCores = cores
                return
            }
            _ = IOObjectRelease(service)
        }
    }

    private func releaseCachedService() {
        if cachedService != 0 {
            _ = IOObjectRelease(cachedService)
            cachedService = 0
        }
        cachedModel = nil
        cachedCores = nil
    }

    private func logMissing() {
        guard !didLogMissing else { return }
        AppLog.sensors.notice("No IOAccelerator utilization source found")
        didLogMissing = true
    }
}
