//
//  MacDoctor/Services/NetworkDiagnosticsProtocols.swift
//  Mac Doctor
//
//  One protocol per Network-tab data source so every diagnostic and lookup
//  service can be replaced with a deterministic mock in previews and tests.
//

import Foundation

protocol ConnectionInfoSampling: Sendable {
    func sample() async -> ConnectionInfo
}

protocol SpeedTesting: Sendable {
    func runTest() async -> SpeedTestState
}

protocol SpeedTestHistoryStoring: Sendable {
    func load() async -> [SpeedTestResult]
    func append(_ result: SpeedTestResult) async -> [SpeedTestResult]
    func clear() async
}

protocol PingTesting: Sendable {
    func ping(host: String) async -> PingState
}

protocol PublicIPLookingUp: Sendable {
    /// Performs a one-shot HTTPS lookup only when explicitly tapped by the user.
    func fetchPublicIP() async -> PublicIPState
}
