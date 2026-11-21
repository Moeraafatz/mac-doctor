//
//  MacDoctor/Services/SubprocessRunner.swift
//  Mac Doctor
//
//  Safe, cancellable subprocess execution with absolute executable URL,
//  explicit argument array (never shell interpolation), non-blocking pipe
//  collection, and a hard timeout.
//

import Foundation
import os

struct SubprocessOutput: Sendable, Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum SubprocessOutcome: Sendable, Equatable {
    case exited(SubprocessOutput)
    case cancelled
    case timedOut
    case launchFailed(String)
}

enum SubprocessRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: Duration
    ) async -> SubprocessOutcome {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return .launchFailed("\(executableURL.path) not found")
        }

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
        let state = OSAllocatedUnfairLock(initialState: (finished: false, cancelled: false))

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
                @Sendable func finishOnce(_ outcome: SubprocessOutcome) {
                    let shouldResume = state.withLock { current -> Bool in
                        if current.finished { return false }
                        current.finished = true
                        return true
                    }
                    guard shouldResume else { return }

                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: outcome)
                }

                let timeoutTask = Task {
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    let stillRunning = state.withLock { !$0.finished }
                    if stillRunning {
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

                    let wasCancelled = state.withLock { $0.cancelled }
                    if wasCancelled {
                        finishOnce(.cancelled)
                        return
                    }

                    if let tail = try? stdoutPipe.fileHandleForReading.readToEnd(), !tail.isEmpty {
                        stdoutBuffer.withLock { $0.append(tail) }
                    }
                    if let errTail = try? stderrPipe.fileHandleForReading.readToEnd(), !errTail.isEmpty {
                        stderrBuffer.withLock { $0.append(errTail) }
                    }

                    let out = String(decoding: stdoutBuffer.withLock { $0 }, as: UTF8.self)
                    let err = String(decoding: stderrBuffer.withLock { $0 }, as: UTF8.self)
                    finishOnce(.exited(SubprocessOutput(
                        exitCode: terminated.terminationStatus,
                        stdout: out,
                        stderr: err
                    )))
                }

                if Task.isCancelled {
                    timeoutTask.cancel()
                    finishOnce(.cancelled)
                    return
                }

                do {
                    try process.run()
                } catch {
                    timeoutTask.cancel()
                    finishOnce(.launchFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            state.withLock { $0.cancelled = true }
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
