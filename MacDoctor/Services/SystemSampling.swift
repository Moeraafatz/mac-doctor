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
    func sample(lightweight: Bool) async -> TemperatureSample?
}

extension TemperatureSampling {
    func sample(lightweight: Bool) async -> TemperatureSample? {
        await sample()
    }
}

/// Active sleep-preventing power assertions via public IOPMCopyAssertionsByProcess.
protocol SleepAssertionSampling: Sendable {
    func sample() async -> [SleepBlocker]
}

/// Controls which hardware subsystems are polled on a given tick so background
/// (popover-closed) operation uses near-zero CPU, wakeups, and power.
enum SamplingScope: Sendable, Equatable {
    /// Popover is open on Overview/Temps/Procs/Network — full hardware telemetry.
    case activeFull(preferFullTemperatures: Bool)
    /// Popover is closed — poll only the minimal subset required for menu bar
    /// readout, threshold alerts, and AC/battery detection.
    case background(includeTemperature: Bool, includeNetwork: Bool)
}

protocol SystemSampling: Sendable {
    func sample() async -> SystemSnapshot
    func sample(scope: SamplingScope) async -> SystemSnapshot
}

extension SystemSampling {
    func sample(scope: SamplingScope) async -> SystemSnapshot {
        await sample()
    }
}
