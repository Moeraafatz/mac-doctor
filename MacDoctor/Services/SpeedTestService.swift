//
//  MacDoctor/Services/SpeedTestService.swift
//  Mac Doctor
//
//  Runs Apple's built-in `/usr/bin/networkQuality -c` (JSON output) off the
//  main thread with a hard timeout and clean cancellation. Never runs unless
//  explicitly started by the user.
//

import Foundation

struct SpeedTestService: SpeedTesting {
    private static let executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
    private static let arguments = ["-c"]

    private let timeout: Duration

    init(timeout: Duration = .seconds(60)) {
        self.timeout = timeout
    }

    func runTest() async -> SpeedTestState {
        AppLog.network.info("SpeedTestService: starting /usr/bin/networkQuality -c")

        let outcome = await SubprocessRunner.run(
            executableURL: Self.executableURL,
            arguments: Self.arguments,
            timeout: timeout
        )

        switch outcome {
        case .cancelled:
            AppLog.network.info("SpeedTestService: speed test cancelled by user")
            return .cancelled

        case .timedOut:
            AppLog.network.error("SpeedTestService: networkQuality timed out")
            return .failed("Speed test timed out.")

        case .launchFailed(let reason):
            AppLog.network.error("SpeedTestService: launch failed: \(reason, privacy: .public)")
            return .failed("Could not start networkQuality: \(reason)")

        case .exited(let output):
            guard output.exitCode == 0 else {
                let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = stderr.isEmpty ? "exit code \(output.exitCode)" : stderr
                AppLog.network.error("SpeedTestService: networkQuality failed: \(detail, privacy: .public)")
                return .failed("Speed test failed: \(detail)")
            }

            guard let parsed = Self.parseJSON(output.stdout) else {
                AppLog.network.error("SpeedTestService: could not parse networkQuality JSON output")
                return .failed("Could not read speed test output.")
            }

            AppLog.network.info(
                "SpeedTestService: complete dl=\(parsed.downloadMbps, privacy: .public) Mbps ul=\(parsed.uploadMbps, privacy: .public) Mbps"
            )
            return .completed(parsed)
        }
    }

    // MARK: - Pure JSON parser (unit-testable)

    /// Parses the JSON produced by `/usr/bin/networkQuality -c`.
    /// `dl_throughput` and `ul_throughput` are reported in bits per second.
    static func parseJSON(_ raw: String, date: Date = .now) -> SpeedTestResult? {
        guard let data = extractJSONObjectData(from: raw),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        guard let dlBitsPerSec = doubleValue(in: json, keys: ["dl_throughput"]),
              let ulBitsPerSec = doubleValue(in: json, keys: ["ul_throughput"])
        else {
            return nil
        }

        let responsiveness: Int? = {
            if let overall = doubleValue(in: json, keys: ["responsiveness"]) {
                return Int(overall.rounded())
            }
            let dlRPM = doubleValue(in: json, keys: ["dl_responsiveness", "downlink_responsiveness_rpm"])
            let ulRPM = doubleValue(in: json, keys: ["ul_responsiveness", "uplink_responsiveness_rpm"])
            switch (dlRPM, ulRPM) {
            case let (dl?, ul?):
                return Int(((dl + ul) / 2.0).rounded())
            case let (dl?, nil):
                return Int(dl.rounded())
            case let (nil, ul?):
                return Int(ul.rounded())
            case (nil, nil):
                return nil
            }
        }()

        let latencyMs = doubleValue(in: json, keys: ["base_rtt", "idle_latency_ms", "latency"])
        let interfaceName = json["interface_name"] as? String

        return SpeedTestResult(
            date: date,
            downloadMbps: dlBitsPerSec / 1_000_000,
            uploadMbps: ulBitsPerSec / 1_000_000,
            responsivenessRPM: responsiveness,
            latencyMs: latencyMs,
            interfaceName: interfaceName
        )
    }

    private static func extractJSONObjectData(from raw: String) -> Data? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start <= end
        else {
            return nil
        }
        return Data(raw[start...end].utf8)
    }

    private static func doubleValue(in dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let number = dictionary[key] as? NSNumber {
                let value = number.doubleValue
                if value.isFinite { return value }
            } else if let text = dictionary[key] as? String, let value = Double(text), value.isFinite {
                return value
            }
        }
        return nil
    }
}
