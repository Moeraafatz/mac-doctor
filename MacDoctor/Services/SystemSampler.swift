//
//  MacDoctor/Services/SystemSampler.swift
//  Mac Doctor
//
//  Tiered adaptive fan-out across hardware services. When the popover is
//  closed, expensive subsystems (GPU, Disk IOKit, Sleep Assertions, 30+ HID
//  temperature sensors) are skipped completely. When open, slow-changing
//  subsystems (Battery, Sleep Assertions, off-tab Temps) are cadence-throttled
//  to minimize kernel crossings and power draw.
//

import Foundation

actor SystemSampler: SystemSampling {
    private let cpu: any CPUSampling
    private let gpu: any GPUSampling
    private let memory: any MemorySampling
    private let disk: any DiskSampling
    private let battery: any BatterySampling
    private let thermal: any ThermalSampling
    private let network: any NetworkSampling
    private let temperatures: any TemperatureSampling
    private let sleepAssertions: any SleepAssertionSampling

    // Cached slow-changing readings + timestamps (systemUptime seconds).
    private var lastGPU: GPUSample?
    private var lastDisk: DiskSample?
    private var lastBattery: (sample: BatterySample?, uptime: TimeInterval)?
    private var lastTemperatures: (sample: TemperatureSample?, isFull: Bool, uptime: TimeInterval)?
    private var lastSleep: (blockers: [SleepBlocker], uptime: TimeInterval)?
    private var lastNetwork: (sample: NetworkSample?, uptime: TimeInterval)?

    private static let activeBatteryTTL: TimeInterval = 6
    private static let backgroundBatteryTTL: TimeInterval = 30
    private static let activeSleepTTL: TimeInterval = 6
    private static let offTabTempTTL: TimeInterval = 4
    private static let backgroundNetworkTTL: TimeInterval = 20

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
        await sample(scope: .activeFull(preferFullTemperatures: true))
    }

    func sample(scope: SamplingScope) async -> SystemSnapshot {
        let nowUptime = ProcessInfo.processInfo.systemUptime

        switch scope {
        case .background(let includeTemperature, let includeNetwork):
            let shouldPollBattery = lastBattery.map { (nowUptime - $0.uptime) >= Self.backgroundBatteryTTL } ?? true
            let shouldPollNetwork = includeNetwork || (lastNetwork.map { (nowUptime - $0.uptime) >= Self.backgroundNetworkTTL } ?? true)

            async let cpuTask = cpu.sample()
            async let memoryTask = memory.sample()
            async let thermalTask = thermal.sample()
            async let batteryTask: BatterySample? = shouldPollBattery ? battery.sample() : nil
            async let networkTask: NetworkSample? = shouldPollNetwork ? network.sample() : nil
            async let tempTask: TemperatureSample? = includeTemperature ? temperatures.sample(lightweight: true) : nil

            let cpuSample = await cpuTask
            let memorySample = await memoryTask
            let thermalSample = await thermalTask

            let batterySample: BatterySample?
            if shouldPollBattery {
                let fresh = await batteryTask
                lastBattery = (fresh, nowUptime)
                batterySample = fresh
            } else {
                batterySample = lastBattery?.sample
            }

            let networkSample: NetworkSample?
            if shouldPollNetwork {
                let fresh = await networkTask
                lastNetwork = (fresh, nowUptime)
                networkSample = fresh
            } else {
                networkSample = lastNetwork?.sample
            }

            let tempSample: TemperatureSample?
            if includeTemperature {
                let fresh = await tempTask
                lastTemperatures = (fresh, false, nowUptime)
                tempSample = fresh
            } else {
                tempSample = lastTemperatures?.sample
            }

            return SystemSnapshot(
                cpu: cpuSample,
                gpu: lastGPU,
                memory: memorySample,
                disk: lastDisk,
                battery: batterySample,
                thermal: thermalSample,
                network: networkSample,
                temperatures: tempSample,
                sleepBlockers: lastSleep?.blockers ?? [],
                capturedAt: .now
            )

        case .activeFull(let preferFullTemperatures):
            let shouldPollBattery = lastBattery.map { (nowUptime - $0.uptime) >= Self.activeBatteryTTL } ?? true
            let shouldPollSleep = lastSleep.map { (nowUptime - $0.uptime) >= Self.activeSleepTTL } ?? true
            let shouldPollTemp: Bool = {
                guard let cached = lastTemperatures else { return true }
                if preferFullTemperatures && !cached.isFull { return true }
                if preferFullTemperatures { return true }
                return (nowUptime - cached.uptime) >= Self.offTabTempTTL
            }()

            async let cpuTask = cpu.sample()
            async let gpuTask = gpu.sample()
            async let memoryTask = memory.sample()
            async let diskTask = disk.sample()
            async let thermalTask = thermal.sample()
            async let networkTask = network.sample()
            async let batteryTask: BatterySample? = shouldPollBattery ? battery.sample() : nil
            async let temperatureTask: TemperatureSample? = shouldPollTemp ? temperatures.sample(lightweight: !preferFullTemperatures) : nil
            async let sleepTask: [SleepBlocker]? = shouldPollSleep ? sleepAssertions.sample() : nil

            let cpuSample = await cpuTask
            let gpuSample = await gpuTask
            let memorySample = await memoryTask
            let diskSample = await diskTask
            let thermalSample = await thermalTask
            let networkSample = await networkTask

            lastGPU = gpuSample
            lastDisk = diskSample
            lastNetwork = (networkSample, nowUptime)

            let batterySample: BatterySample?
            if shouldPollBattery {
                let fresh = await batteryTask
                lastBattery = (fresh, nowUptime)
                batterySample = fresh
            } else {
                batterySample = lastBattery?.sample
            }

            let temperatureSample: TemperatureSample?
            if shouldPollTemp {
                let fresh = await temperatureTask
                lastTemperatures = (fresh, preferFullTemperatures, nowUptime)
                temperatureSample = fresh
            } else {
                temperatureSample = lastTemperatures?.sample
            }

            let sleepBlockers: [SleepBlocker]
            if shouldPollSleep {
                let fresh = await sleepTask ?? []
                lastSleep = (fresh, nowUptime)
                sleepBlockers = fresh
            } else {
                sleepBlockers = lastSleep?.blockers ?? []
            }

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
}
