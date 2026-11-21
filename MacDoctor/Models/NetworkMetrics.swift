//
//  MacDoctor/Models/NetworkMetrics.swift
//  Mac Doctor
//
//  Immutable, Sendable models for the Network tab: live throughput history,
//  speed tests (/usr/bin/networkQuality), ping diagnostics (/sbin/ping),
//  connection & CoreWLAN Wi-Fi details, strict host validation, and on-demand
//  public IP lookup.
//

import Darwin
import Foundation

// MARK: - Live throughput history

struct ThroughputPoint: Identifiable, Sendable, Equatable {
    let id: UUID
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
    let timestamp: Date

    init(
        id: UUID = UUID(),
        downloadBytesPerSecond: Double,
        uploadBytesPerSecond: Double,
        timestamp: Date = .now
    ) {
        self.id = id
        self.downloadBytesPerSecond = max(0, downloadBytesPerSecond)
        self.uploadBytesPerSecond = max(0, uploadBytesPerSecond)
        self.timestamp = timestamp
    }
}

// MARK: - Speed test

struct SpeedTestResult: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let date: Date
    let downloadMbps: Double
    let uploadMbps: Double
    let responsivenessRPM: Int?
    let latencyMs: Double?
    let interfaceName: String?

    init(
        id: UUID = UUID(),
        date: Date = .now,
        downloadMbps: Double,
        uploadMbps: Double,
        responsivenessRPM: Int?,
        latencyMs: Double?,
        interfaceName: String?
    ) {
        self.id = id
        self.date = date
        self.downloadMbps = max(0, downloadMbps)
        self.uploadMbps = max(0, uploadMbps)
        self.responsivenessRPM = responsivenessRPM
        self.latencyMs = latencyMs
        self.interfaceName = interfaceName
    }
}

enum SpeedTestState: Sendable, Equatable {
    case idle
    case running(startedAt: Date)
    case completed(SpeedTestResult)
    case cancelled
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

// MARK: - Ping & strict host validation

enum PingHostPreset: String, CaseIterable, Identifiable, Sendable {
    case cloudflare = "1.1.1.1"
    case google = "8.8.8.8"
    case custom = "custom"

    var id: Self { self }

    var label: String {
        switch self {
        case .cloudflare: "1.1.1.1"
        case .google: "8.8.8.8"
        case .custom: "Custom"
        }
    }

    var defaultHost: String {
        switch self {
        case .cloudflare: "1.1.1.1"
        case .google: "8.8.8.8"
        case .custom: ""
        }
    }
}

enum HostValidator {
    /// Strict RFC 1123 hostname regex (ASCII labels separated by dots, no leading
    /// hyphen, no shell metacharacters, no whitespace).
    private static let hostnamePattern =
        #"^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"#

    /// Validates and normalizes a ping target. Returns a clean host string only
    /// if it is a valid IPv4 address or strict ASCII hostname. Rejects options
    /// (leading `-`), whitespace, paths, and shell metacharacters.
    static func validatedHost(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 253 else { return nil }
        guard !trimmed.hasPrefix("-") else { return nil }

        // Only allow ASCII characters that can appear in an IPv4 address or hostname.
        guard trimmed.unicodeScalars.allSatisfy({ scalar in
            (scalar.value >= 48 && scalar.value <= 57)      // 0-9
                || (scalar.value >= 65 && scalar.value <= 90)  // A-Z
                || (scalar.value >= 97 && scalar.value <= 122) // a-z
                || scalar.value == 45                          // -
                || scalar.value == 46                          // .
        }) else {
            return nil
        }

        if isValidIPv4(trimmed) {
            return trimmed
        }

        // If every character is a digit or dot, it was an attempted IPv4 that failed inet_pton.
        if trimmed.allSatisfy({ $0.isNumber || $0 == "." }) {
            return nil
        }

        guard trimmed.range(of: hostnamePattern, options: .regularExpression) != nil else {
            return nil
        }

        return trimmed
    }

    static func isValidIPv4(_ text: String) -> Bool {
        var addr = in_addr()
        return text.withCString { inet_pton(AF_INET, $0, &addr) == 1 }
    }

    static func isValidIPv6(_ text: String) -> Bool {
        var addr = in6_addr()
        return text.withCString { inet_pton(AF_INET6, $0, &addr) == 1 }
    }

    static func isValidIP(_ text: String) -> Bool {
        isValidIPv4(text) || isValidIPv6(text)
    }
}

struct PingResult: Sendable, Equatable {
    let host: String
    let resolvedIP: String?
    let transmitted: Int
    let received: Int
    let packetLossPercent: Double
    let minMs: Double?
    let avgMs: Double?
    let maxMs: Double?
    let jitterMs: Double?
    let date: Date
}

enum PingState: Sendable, Equatable {
    case idle
    case running(host: String)
    case completed(PingResult)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

// MARK: - Connection & Wi-Fi info

enum NetworkInterfaceKind: String, Sendable, Equatable {
    case wifi = "Wi-Fi"
    case ethernet = "Ethernet"
    case other = "Network"
    case disconnected = "Offline"

    var symbol: String {
        switch self {
        case .wifi: "wifi"
        case .ethernet: "cable.connector"
        case .other: "network"
        case .disconnected: "wifi.slash"
        }
    }
}

enum SSIDStatus: Sendable, Equatable {
    case available(String)
    case hiddenPermissionNeeded
    case unavailable

    var displayText: String {
        switch self {
        case .available(let ssid): ssid
        case .hiddenPermissionNeeded: "Hidden (permission needed)"
        case .unavailable: "Unavailable"
        }
    }
}

struct WiFiDetails: Sendable, Equatable {
    let ssidStatus: SSIDStatus
    let rssi: Int?
    let noise: Int?
    let channelNumber: Int?
    let channelBand: String?
    let channelWidthMHz: Int?
    let transmitRateMbps: Double?

    var signalToNoise: Int? {
        guard let rssi, let noise else { return nil }
        return rssi - noise
    }

    var channelSummary: String {
        var parts: [String] = []
        if let channelNumber { parts.append("Ch \(channelNumber)") }
        if let channelBand { parts.append(channelBand) }
        if let channelWidthMHz { parts.append("\(channelWidthMHz) MHz") }
        return parts.isEmpty ? "Unavailable" : parts.joined(separator: " · ")
    }
}

struct ConnectionInfo: Sendable, Equatable {
    let interfaceName: String?
    let interfaceKind: NetworkInterfaceKind
    let localIP: String?
    let routerIP: String?
    let dnsServers: [String]
    let vpnInterface: String?
    let wifi: WiFiDetails?
    let capturedAt: Date

    static let empty = ConnectionInfo(
        interfaceName: nil,
        interfaceKind: .disconnected,
        localIP: nil,
        routerIP: nil,
        dnsServers: [],
        vpnInterface: nil,
        wifi: nil,
        capturedAt: .distantPast
    )
}

// MARK: - Public IP (on-demand only)

enum PublicIPState: Sendable, Equatable {
    case hidden
    case loading
    case visible(String)
    case failed(String)
}

#if DEBUG
extension ConnectionInfo {
    static let preview = ConnectionInfo(
        interfaceName: "en0",
        interfaceKind: .wifi,
        localIP: "192.168.1.42",
        routerIP: "192.168.1.1",
        dnsServers: ["1.1.1.1", "8.8.8.8"],
        vpnInterface: nil,
        wifi: WiFiDetails(
            ssidStatus: .hiddenPermissionNeeded,
            rssi: -54,
            noise: -92,
            channelNumber: 149,
            channelBand: "5 GHz",
            channelWidthMHz: 80,
            transmitRateMbps: 866
        ),
        capturedAt: .now
    )
}

extension SpeedTestResult {
    static let previewHistory: [SpeedTestResult] = [
        SpeedTestResult(
            date: Date().addingTimeInterval(-300),
            downloadMbps: 412.6,
            uploadMbps: 118.4,
            responsivenessRPM: 1040,
            latencyMs: 11.4,
            interfaceName: "en0"
        ),
        SpeedTestResult(
            date: Date().addingTimeInterval(-7200),
            downloadMbps: 389.1,
            uploadMbps: 112.0,
            responsivenessRPM: 965,
            latencyMs: 13.8,
            interfaceName: "en0"
        )
    ]
}
#endif
