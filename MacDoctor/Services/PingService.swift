//
//  MacDoctor/Services/PingService.swift
//  Mac Doctor
//
//  Runs `/sbin/ping` with a fixed packet count, interval, and timeout using an
//  explicit argument array (never shell interpolation). Validates the host
//  strictly with `HostValidator` before launching any process.
//

import Foundation

struct PingService: PingTesting {
    private static let executableURL = URL(fileURLWithPath: "/sbin/ping")

    private let packetCount: Int
    private let hardTimeoutSeconds: Int
    private let processTimeout: Duration

    init(
        packetCount: Int = 5,
        hardTimeoutSeconds: Int = 6,
        processTimeout: Duration = .seconds(8)
    ) {
        self.packetCount = max(1, min(packetCount, 10))
        self.hardTimeoutSeconds = max(2, min(hardTimeoutSeconds, 15))
        self.processTimeout = processTimeout
    }

    func ping(host: String) async -> PingState {
        guard let validHost = HostValidator.validatedHost(host) else {
            AppLog.network.notice("PingService: rejected invalid host input")
            return .failed("Invalid host. Enter an IPv4 address or hostname (e.g. 1.1.1.1 or apple.com).")
        }

        let arguments = [
            "-c", String(packetCount),
            "-i", "0.2",
            "-t", String(hardTimeoutSeconds),
            "-n",
            "--",
            validHost
        ]

        let outcome = await SubprocessRunner.run(
            executableURL: Self.executableURL,
            arguments: arguments,
            timeout: processTimeout
        )

        switch outcome {
        case .cancelled:
            return .idle

        case .timedOut:
            AppLog.network.error("PingService: /sbin/ping timed out for \(validHost, privacy: .public)")
            return .failed("Ping to \(validHost) timed out.")

        case .launchFailed(let reason):
            AppLog.network.error("PingService: launch failed: \(reason, privacy: .public)")
            return .failed("Could not run /sbin/ping: \(reason)")

        case .exited(let output):
            // macOS /sbin/ping exits with 0 on replies or 2 on 100% packet loss.
            if let parsed = Self.parse(output: output.stdout, host: validHost) {
                return .completed(parsed)
            }

            let err = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = err.isEmpty ? "exit code \(output.exitCode)" : err
            AppLog.network.error("PingService: ping failed for \(validHost, privacy: .public): \(detail, privacy: .public)")
            return .failed("Ping failed: \(detail)")
        }
    }

    // MARK: - Pure output parser (unit-testable)

    static func parse(output: String, host: String, date: Date = .now) -> PingResult? {
        var resolvedIP: String?
        var replyTimes: [Double] = []
        var transmitted: Int?
        var received: Int?
        var packetLoss: Double?
        var minMs: Double?
        var avgMs: Double?
        var maxMs: Double?
        var stddevMs: Double?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if resolvedIP == nil, line.hasPrefix("PING "),
               let openParen = line.firstIndex(of: "("),
               let closeParen = line[openParen...].firstIndex(of: ")"),
               openParen < closeParen {
                let candidate = String(line[line.index(after: openParen)..<closeParen])
                if HostValidator.isValidIP(candidate) {
                    resolvedIP = candidate
                }
            }

            if let timeRange = line.range(of: "time=") {
                let after = line[timeRange.upperBound...]
                if let token = after.split(separator: " ").first, let ms = Double(token), ms.isFinite {
                    replyTimes.append(ms)
                }
            }

            if line.contains("packets transmitted"), line.contains("packet loss") {
                let parsed = parsePacketLine(line)
                transmitted = parsed.transmitted
                received = parsed.received
                packetLoss = parsed.loss
            }

            if line.hasPrefix("round-trip "), let equals = line.firstIndex(of: "=") {
                let rhs = line[line.index(after: equals)...]
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: " ms", with: "")
                let parts = rhs.split(separator: "/").compactMap { Double($0) }
                if parts.count >= 4 {
                    minMs = parts[0]
                    avgMs = parts[1]
                    maxMs = parts[2]
                    stddevMs = parts[3]
                }
            }
        }

        guard let transmitted, let received else { return nil }

        let computedLoss: Double = {
            if let packetLoss { return packetLoss }
            guard transmitted > 0 else { return 100 }
            return Double(transmitted - received) / Double(transmitted) * 100.0
        }()

        // Mean consecutive RTT difference is the standard jitter definition;
        // fall back to ping's reported stddev if fewer than 2 individual replies.
        let jitter: Double? = {
            if replyTimes.count >= 2 {
                var sumDiff = 0.0
                for idx in 1..<replyTimes.count {
                    sumDiff += abs(replyTimes[idx] - replyTimes[idx - 1])
                }
                return sumDiff / Double(replyTimes.count - 1)
            }
            return stddevMs
        }()

        return PingResult(
            host: host,
            resolvedIP: resolvedIP,
            transmitted: transmitted,
            received: received,
            packetLossPercent: min(max(computedLoss, 0), 100),
            minMs: minMs ?? replyTimes.min(),
            avgMs: avgMs ?? (replyTimes.isEmpty ? nil : replyTimes.reduce(0, +) / Double(replyTimes.count)),
            maxMs: maxMs ?? replyTimes.max(),
            jitterMs: jitter,
            date: date
        )
    }

    private static func parsePacketLine(_ line: String) -> (transmitted: Int?, received: Int?, loss: Double?) {
        let segments = line.split(separator: ",")
        var tx: Int?
        var rx: Int?
        var loss: Double?

        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("transmitted"), let first = trimmed.split(separator: " ").first {
                tx = Int(first)
            } else if trimmed.contains("received"), let first = trimmed.split(separator: " ").first {
                rx = Int(first)
            } else if trimmed.contains("packet loss"), let percentIndex = trimmed.firstIndex(of: "%") {
                let prefix = trimmed[..<percentIndex].trimmingCharacters(in: .whitespaces)
                if let token = prefix.split(separator: " ").last {
                    loss = Double(token)
                }
            }
        }

        return (tx, rx, loss)
    }
}
