//
//  ThermalService.swift
//  Mac Doctor
//
//  ProcessInfo exposes the same thermal pressure state macOS uses for
//  scheduler decisions, with no privileged access required.
//

import Foundation

struct ThermalService: ThermalSampling {
    func sample() async -> ThermalSample {
        let info = ProcessInfo.processInfo

        let condition: ThermalCondition
        switch info.thermalState {
        case .nominal: condition = .nominal
        case .fair: condition = .fair
        case .serious: condition = .serious
        case .critical: condition = .critical
        @unknown default: condition = .nominal
        }

        return ThermalSample(
            condition: condition,
            lowPowerMode: info.isLowPowerModeEnabled
        )
    }
}
