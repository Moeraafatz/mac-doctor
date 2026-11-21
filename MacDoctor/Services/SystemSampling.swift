//
//  MacDoctor/Services/SystemSampling.swift
//  Mac Doctor
//
//  One protocol per data source so every reading can be replaced with a
//  deterministic mock in previews and tests. Services are actors; sampling
//  therefore never runs on the main thread.
//

import Foundation

protocol CPUSampling: Sendable {
    func sample() async -> CPUSample
}

protocol GPUSampling: Sendable {
    func sample() async -> GPUSample?
}

protocol MemorySampling: Sendable {
    func sample() async -> MemorySample?
}

protocol DiskSampling: Sendable {
    func sample() async -> DiskSample?
}

protocol BatterySampling: Sendable {
    func sample() async -> BatterySample?
}

protocol ThermalSampling: Sendable {
    func sample() async -> ThermalSample
}

protocol NetworkSampling: Sendable {
    func sample() async -> NetworkSample?
}

/// Per-sensor temperatures. Backed by SensorBridge (private API, isolated).
protocol TemperatureSampling: Sendable {
    func sample() async -> TemperatureSample?
}

/// Active sleep-preventing power assertions via public IOPMCopyAssertionsByProcess.
protocol SleepAssertionSampling: Sendable {
    func sample() async -> [SleepBlocker]
}

protocol SystemSampling: Sendable {
    func sample() async -> SystemSnapshot
}
