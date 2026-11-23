//
//  MacDoctor/ViewModels/NetworkStore.swift
//  Mac Doctor
//
//  Main-actor view model for the Network tab. Coordinates local connection /
//  CoreWLAN polling, user-initiated speed tests (with cancel and 20-entry
//  local history), user-initiated ping with strict host validation, and
//  on-demand public IP lookup (hidden by default).
//

import AppKit
import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class NetworkStore {
    private(set) var connectionInfo: ConnectionInfo = .empty
    private(set) var speedTestState: SpeedTestState = .idle
    private(set) var speedTestHistory: [SpeedTestResult] = []
    private(set) var pingState: PingState = .idle
    private(set) var isLivePingRunning = false
    private(set) var livePingHistory: [Double] = []
    private(set) var livePingSent = 0
    private(set) var livePingLost = 0
    private(set) var publicIPState: PublicIPState = .hidden

    var pingPreset: PingHostPreset = .cloudflare
    var customPingHost: String = ""

    private let connectionService: any ConnectionInfoSampling
    private let speedTestService: any SpeedTesting
    private let historyStore: any SpeedTestHistoryStoring
    private let pingService: any PingTesting
    private let singlePingService: any PingTesting
    private let publicIPService: any PublicIPLookingUp

    @ObservationIgnored private var speedTestTask: Task<Void, Never>?
    @ObservationIgnored private var pingTask: Task<Void, Never>?
    @ObservationIgnored private var livePingTask: Task<Void, Never>?
    @ObservationIgnored private var publicIPTask: Task<Void, Never>?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var isPopoverVisible = false
    @ObservationIgnored private var isNetworkTabVisible = false
    @ObservationIgnored private var didLoadHistory = false
    @ObservationIgnored private var locationHelper: LocationPermissionHelper?

    init(
        connectionService: any ConnectionInfoSampling = ConnectionInfoService(),
        speedTestService: any SpeedTesting = SpeedTestService(),
        historyStore: any SpeedTestHistoryStoring = SpeedTestHistoryStore(),
        pingService: any PingTesting = PingService(),
        publicIPService: any PublicIPLookingUp = PublicIPService(),
        initialConnectionInfo: ConnectionInfo = .empty,
        initialHistory: [SpeedTestResult] = []
    ) {
        self.connectionService = connectionService
        self.speedTestService = speedTestService
        self.historyStore = historyStore
        self.pingService = pingService
        self.singlePingService = PingService(packetCount: 1, hardTimeoutSeconds: 2, processTimeout: .seconds(3))
        self.publicIPService = publicIPService
        self.connectionInfo = initialConnectionInfo
        self.speedTestHistory = initialHistory
        if !initialHistory.isEmpty {
            self.didLoadHistory = true
        }
    }

    var effectivePingHost: String {
        switch pingPreset {
        case .cloudflare, .google:
            pingPreset.defaultHost
        case .custom:
            customPingHost.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var isPingHostValid: Bool {
        HostValidator.validatedHost(effectivePingHost) != nil
    }

    // MARK: - Lifecycle & local connection polling

    func setPopoverVisible(_ visible: Bool) {
        guard isPopoverVisible != visible else { return }
        isPopoverVisible = visible
        if !visible && isLivePingRunning {
            stopLivePing()
        }
        updatePollingState()
    }

    func setNetworkTabVisible(_ visible: Bool) {
        guard isNetworkTabVisible != visible else { return }
        isNetworkTabVisible = visible
        if !visible && isLivePingRunning {
            stopLivePing()
        }
        updatePollingState()
    }

    private func updatePollingState() {
        let shouldPoll = isPopoverVisible && isNetworkTabVisible
        if shouldPoll {
            guard pollingTask == nil else { return }
            pollingTask = Task(priority: .utility) { [weak self] in
                await self?.runConnectionPolling()
            }
        } else {
            pollingTask?.cancel()
            pollingTask = nil
        }
    }

    func runConnectionPolling() async {
        if !didLoadHistory {
            speedTestHistory = await historyStore.load()
            didLoadHistory = true
        }

        while !Task.isCancelled {
            await refreshConnectionInfo()

            do {
                try await Task.sleep(for: .seconds(5), tolerance: .seconds(1))
            } catch {
                return
            }
        }
    }

    func refreshConnectionInfo() async {
        let info = await connectionService.sample()
        guard !Task.isCancelled else { return }
        connectionInfo = info
    }

    // MARK: - Speed test (user-initiated)

    func startSpeedTest() {
        guard !speedTestState.isRunning else { return }
        speedTestTask?.cancel()
        speedTestState = .running(startedAt: .now)

        speedTestTask = Task {
            let outcome = await speedTestService.runTest()
            guard !Task.isCancelled else {
                speedTestState = .cancelled
                return
            }
            speedTestState = outcome

            if case .completed(let result) = outcome {
                speedTestHistory = await historyStore.append(result)
            }
        }
    }

    func cancelSpeedTest() {
        speedTestTask?.cancel()
        speedTestTask = nil
        if speedTestState.isRunning {
            speedTestState = .cancelled
        }
    }

    func clearSpeedTestHistory() {
        Task {
            await historyStore.clear()
            speedTestHistory = []
        }
    }

    // MARK: - Ping (user-initiated)

    func runPing() {
        let rawHost = effectivePingHost
        guard let validHost = HostValidator.validatedHost(rawHost) else {
            pingState = .failed("Enter a valid IPv4 address or hostname.")
            return
        }

        pingTask?.cancel()
        pingState = .running(host: validHost)

        pingTask = Task {
            let outcome = await pingService.ping(host: validHost)
            guard !Task.isCancelled else { return }
            pingState = outcome
        }
    }

    func cancelPing() {
        pingTask?.cancel()
        pingTask = nil
        if pingState.isRunning {
            pingState = .idle
        }
    }

    func toggleLivePing() {
        if isLivePingRunning {
            stopLivePing()
        } else {
            startLivePing()
        }
    }

    func startLivePing() {
        guard let validHost = HostValidator.validatedHost(effectivePingHost) else {
            pingState = .failed("Enter a valid IPv4 address or hostname.")
            return
        }
        cancelPing()
        livePingTask?.cancel()
        livePingHistory = []
        livePingSent = 0
        livePingLost = 0
        isLivePingRunning = true

        livePingTask = Task {
            while !Task.isCancelled {
                let outcome = await singlePingService.ping(host: validHost)
                guard !Task.isCancelled else { break }

                livePingSent += 1
                if case .completed(let result) = outcome, let ms = result.avgMs {
                    livePingHistory.append(ms)
                    if livePingHistory.count > 30 {
                        livePingHistory.removeFirst(livePingHistory.count - 30)
                    }
                    let avg = livePingHistory.reduce(0, +) / Double(livePingHistory.count)
                    var jitter: Double? = nil
                    if livePingHistory.count >= 2 {
                        var sum = 0.0
                        for i in 1..<livePingHistory.count {
                            sum += abs(livePingHistory[i] - livePingHistory[i - 1])
                        }
                        jitter = sum / Double(livePingHistory.count - 1)
                    }
                    let loss = Double(livePingLost) / Double(max(livePingSent, 1)) * 100.0
                    pingState = .completed(PingResult(
                        host: validHost,
                        resolvedIP: result.resolvedIP,
                        transmitted: livePingSent,
                        received: livePingSent - livePingLost,
                        packetLossPercent: loss,
                        minMs: livePingHistory.min(),
                        avgMs: avg,
                        maxMs: livePingHistory.max(),
                        jitterMs: jitter,
                        date: .now
                    ))
                } else {
                    livePingLost += 1
                }

                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
            }
            isLivePingRunning = false
        }
    }

    func stopLivePing() {
        livePingTask?.cancel()
        livePingTask = nil
        isLivePingRunning = false
    }

    // MARK: - Public IP (on-demand only)

    func togglePublicIP() {
        switch publicIPState {
        case .hidden, .failed:
            fetchPublicIP()
        case .loading:
            publicIPTask?.cancel()
            publicIPTask = nil
            publicIPState = .hidden
        case .visible:
            publicIPState = .hidden
        }
    }

    private func fetchPublicIP() {
        publicIPTask?.cancel()
        publicIPState = .loading

        publicIPTask = Task {
            let outcome = await publicIPService.fetchPublicIP()
            guard !Task.isCancelled else {
                publicIPState = .hidden
                return
            }
            publicIPState = outcome
        }
    }

    // MARK: - Location permission for SSID

    func requestLocationPermission() {
        let helper = locationHelper ?? {
            let created = LocationPermissionHelper()
            created.onAuthorizationChange = { [weak self] in
                Task { @MainActor in
                    await self?.refreshConnectionInfo()
                }
            }
            self.locationHelper = created
            return created
        }()
        helper.requestOrOpenSettings()
    }
}

// MARK: - CoreLocation permission helper

@MainActor
private final class LocationPermissionHelper: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onAuthorizationChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    func requestOrOpenSettings() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                NSWorkspace.shared.open(url)
            }
        case .authorizedAlways:
            onAuthorizationChange?()
        @unknown default:
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.onAuthorizationChange?()
        }
    }
}
