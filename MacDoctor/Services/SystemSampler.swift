//
//  MacDoctor/Services/SystemSampler.swift
//  Mac Doctor
//
//  Fan-out point for the nine independent data sources. Each service is an
//  actor (or a stateless struct), so this struct can call them concurrently
//  without any main-thread work.
//

import Foundation

struct SystemSampler: SystemSampling {
    private let cpu: any CPUSampling
    private let gpu: any GPUSampling
    private let memory: any MemorySampling
    private let disk: any DiskSampling
    private let battery: any BatterySampling
    private let thermal: any ThermalSampling
    private let network: any NetworkSampling
    private let temperatures: any TemperatureSampling
    private let sleepAssertions: any SleepAssertionSampling

    init(
        cpu: any CPUSampling = CPUService(),
        gpu: any GPUSampling = GPUService(),
        memory: any MemorySampling = MemoryService(),
        disk: any DiskSampling = DiskService(),
        battery: any BatterySampling = BatteryService(),
        thermal: any ThermalSampling = ThermalService(),
        network: any NetworkSampling = NetworkService(),
        temperatures: any TemperatureSampling = TemperatureService(),
        sleepAssertions: any SleepAssertionSampling = SleepAssertionService()
    ) {
        self.cpu = cpu
        self.gpu = gpu
        self.memory = memory
        self.disk = disk
        self.battery = battery
        self.thermal = thermal
        self.network = network
        self.temperatures = temperatures
        self.sleepAssertions = sleepAssertions
    }

    func sample() async -> SystemSnapshot {
        async let cpuTask = cpu.sample()
        async let gpuTask = gpu.sample()
        async let memoryTask = memory.sample()
        async let diskTask = disk.sample()
        async let batteryTask = battery.sample()
        async let thermalTask = thermal.sample()
        async let networkTask = network.sample()
        async let temperatureTask = temperatures.sample()
        async let sleepTask = sleepAssertions.sample()

        let cpuSample = await cpuTask
        let gpuSample = await gpuTask
        let memorySample = await memoryTask
        let diskSample = await diskTask
        let batterySample = await batteryTask
        let thermalSample = await thermalTask
        let networkSample = await networkTask
        let temperatureSample = await temperatureTask
        let sleepBlockers = await sleepTask

        return SystemSnapshot(
            cpu: cpuSample,
            gpu: gpuSample,
            memory: memorySample,
            disk: diskSample,
            battery: batterySample,
            thermal: thermalSample,
            network: networkSample,
            temperatures: temperatureSample,
            sleepBlockers: sleepBlockers,
            capturedAt: .now
        )
    }
}
