//
//  MacDoctor/Services/ProcessSampling.swift
//  Mac Doctor
//
//  Protocols for the Processes (Task Manager) services so sampling, nettop
//  parsing, and quit/force-quit control can each be mocked in previews and
//  unit tests.
//

import Foundation

struct NettopCounter: Sendable, Equatable {
    var bytesIn: UInt64
    var bytesOut: UInt64
}

protocol NettopSampling: Sendable {
    /// Returns cumulative bytes in/out per PID, or `nil` if `/usr/bin/nettop`
    /// timed out or failed.
    func sample() async -> [pid_t: NettopCounter]?
}

protocol ProcessSampling: Sendable {
    func sample(includeNetwork: Bool) async -> ProcessSnapshot
}

protocol ProcessControlling: Sendable {
    func quit(_ entry: ProcessEntry) async -> ProcessActionResult
    func forceQuit(_ entry: ProcessEntry) async -> ProcessActionResult
    func relaunchFinder() async -> ProcessActionResult
}
