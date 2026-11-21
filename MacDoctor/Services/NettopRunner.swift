//
//  MacDoctor/Services/NettopRunner.swift
//  Mac Doctor
//
//  Runs Apple's built-in `/usr/bin/nettop` in non-interactive logging mode
//  (single sample) using an explicit argument array and a strict timeout.
//  Parses cumulative bytes_in / bytes_out per PID and degrades cleanly to
//  `nil` if nettop fails, times out, or is unavailable.
//

import Foundation
import os

actor NettopRunner: NettopSampling {
    private static let executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
    private static let arguments = ["-P", "-L", "1", "-n", "-J", "bytes_in,bytes_out"]

    private let timeout: Duration
    private var didLogFailure = false

    init(timeout: Duration = .seconds(4)) {
        self.timeout = timeout
    }

    func sample() async -> [pid_t: NettopCounter]? {
        guard FileManager.default.isExecutableFile(atPath: Self.executableURL.path) else {
            logFailureOnce("/usr/bin/nettop not found")
            return nil
        }

        let result = await Self.runProcess(
            executableURL: Self.executableURL,
            arguments: Self.arguments,
            timeout: timeout
        )

        switch result {
        case .success(let output):
            guard let parsed = Self.parse(output) else {
                logFailureOnce("nettop output did not contain a valid header")
                return nil
            }
            didLogFailure = false
            return parsed
        case .timedOut:
            logFailureOnce("nettop timed out after \(timeout)")
            return nil
        case .failed(let reason):
            logFailureOnce("nettop failed: \(reason)")
            return nil
        }
    }

    // MARK: - Parser (pure, unit-testable)

    /// Parses CSV output from `/usr/bin/nettop -P -L 1 -n -J bytes_in,bytes_out`.
    /// Expected format:
    ///   ,bytes_in,bytes_out,
    ///   python3.11.973,1234,5678,
    ///   com.apple.WebKi.14073,17442434,254519,
    ///
    /// Process names may contain dots or spaces, so the PID is extracted after
    /// the last '.' in the first column.
    static func parse(_ output: String) -> [pid_t: NettopCounter]? {
        var result: [pid_t: NettopCounter] = [:]
        var bytesInColumn = 1
        var bytesOutColumn = 2
        var sawHeader = false

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.count >= 3 else { continue }

            if !sawHeader, columns[0].isEmpty {
                for (index, column) in columns.enumerated() {
                    if column == "bytes_in" { bytesInColumn = index }
                    if column == "bytes_out" { bytesOutColumn = index }
                }
                sawHeader = true
                continue
            }

            guard sawHeader else { continue }
            guard bytesInColumn < columns.count, bytesOutColumn < columns.count else { continue }

            let processField = columns[0]
            guard let dotIndex = processField.lastIndex(of: ".") else { continue }
            let pidSlice = processField[processField.index(after: dotIndex)...]

            guard let pid = pid_t(pidSlice),
                  let bytesIn = UInt64(columns[bytesInColumn]),
                  let bytesOut = UInt64(columns[bytesOutColumn])
            else {
                continue
            }

            if var existing = result[pid] {
                existing.bytesIn &+= bytesIn
                existing.bytesOut &+= bytesOut
                result[pid] = existing
            } else {
                result[pid] = NettopCounter(bytesIn: bytesIn, bytesOut: bytesOut)
            }
        }

        return sawHeader ? result : nil
    }

    // MARK: - Subprocess execution with timeout

    private enum RunResult: Sendable {
        case success(String)
        case timedOut
        case failed(String)
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        timeout: Duration
    ) async -> RunResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let stdoutBuffer = OSAllocatedUnfairLock(initialState: Data())
        let stderrBuffer = OSAllocatedUnfairLock(initialState: Data())
        let finished = OSAllocatedUnfairLock(initialState: false)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stdoutBuffer.withLock { $0.append(chunk) }
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBuffer.withLock { $0.append(chunk) }
            }
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                @Sendable func finishOnce(_ result: RunResult) {
                    let shouldResume = finished.withLock { alreadyFinished -> Bool in
                        if alreadyFinished { return false }
                        alreadyFinished = true
                        return true
                    }
                    guard shouldResume else { return }

                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: result)
                }

                let timeoutTask = Task {
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    let needsKill = finished.withLock { !$0 }
                    if needsKill {
                        if process.isRunning {
                            process.terminate()
                        }
                        finishOnce(.timedOut)
                    }
                }

                process.terminationHandler = { terminated in
                    timeoutTask.cancel()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    // Drain any remaining bytes buffered in the kernel pipe.
                    if let tail = try? stdoutPipe.fileHandleForReading.readToEnd(), !tail.isEmpty {
                        stdoutBuffer.withLock { $0.append(tail) }
                    }
                    if let errTail = try? stderrPipe.fileHandleForReading.readToEnd(), !errTail.isEmpty {
                        stderrBuffer.withLock { $0.append(errTail) }
                    }

                    let outData = stdoutBuffer.withLock { $0 }
                    let errData = stderrBuffer.withLock { $0 }

                    if terminated.terminationStatus == 0 {
                        let text = String(decoding: outData, as: UTF8.self)
                        finishOnce(.success(text))
                    } else {
                        let stderrText = String(decoding: errData, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let detail = stderrText.isEmpty
                            ? "exit code \(terminated.terminationStatus)"
                            : stderrText
                        finishOnce(.failed(detail))
                    }
                }

                do {
                    try process.run()
                } catch {
                    timeoutTask.cancel()
                    finishOnce(.failed(error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private func logFailureOnce(_ message: String) {
        guard !didLogFailure else { return }
        AppLog.processes.error("\(message, privacy: .public)")
        didLogFailure = true
    }
}
