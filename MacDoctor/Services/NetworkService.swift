//
//  NetworkService.swift
//  Mac Doctor
//
//  Aggregate throughput for the active Ethernet/Wi-Fi interfaces. getifaddrs
//  exposes 32-bit byte counters, so deltas use wrapping subtraction; a 4 GB
//  wrap between two-second samples is not physically possible.
//

import Darwin
import Foundation

actor NetworkService: NetworkSampling {
    private struct Counters: Sendable {
        var received: UInt32
        var sent: UInt32
    }

    private var previous: [String: Counters] = [:]
    private var previousUptime: TimeInterval?
    private var didLogFailure = false

    func sample() async -> NetworkSample? {
        guard let interfaces = Self.readInterfaces() else {
            if !didLogFailure {
                AppLog.network.error("getifaddrs failed")
                didLogFailure = true
            }
            return nil
        }

        let uptime = ProcessInfo.processInfo.systemUptime
        var receivedDelta: Double = 0
        var sentDelta: Double = 0
        var hasPrevious = false
        var next: [String: Counters] = [:]

        for (name, counters) in interfaces {
            next[name] = counters

            guard let previous = previous[name] else { continue }
            hasPrevious = true
            receivedDelta += Double(counters.received &- previous.received)
            sentDelta += Double(counters.sent &- previous.sent)
        }

        var downloadRate: Double?
        var uploadRate: Double?

        if hasPrevious, let previousUptime {
            let elapsed = max(uptime - previousUptime, 0.1)
            downloadRate = receivedDelta / elapsed
            uploadRate = sentDelta / elapsed
        }

        previous = next
        previousUptime = uptime

        let activeNames = interfaces
            .filter { $0.value.received > 0 || $0.value.sent > 0 }
            .keys
            .sorted()

        let interfaceName: String?
        if activeNames.count == 1 {
            interfaceName = activeNames[0]
        } else if activeNames.count > 1 {
            interfaceName = "\(activeNames.count) interfaces"
        } else {
            interfaceName = nil
        }

        return NetworkSample(
            downloadBytesPerSecond: downloadRate,
            uploadBytesPerSecond: uploadRate,
            interfaceName: interfaceName
        )
    }

    private static func readInterfaces() -> [String: Counters]? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return nil
        }
        defer { freeifaddrs(first) }

        var result: [String: Counters] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first

        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }

            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let data = interface.pointee.ifa_data
            else {
                continue
            }

            let name = String(cString: interface.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }

            let flags = interface.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_RUNNING) != 0
            else {
                continue
            }

            let statistics = data.assumingMemoryBound(to: if_data.self).pointee
            result[name] = Counters(
                received: statistics.ifi_ibytes,
                sent: statistics.ifi_obytes
            )
        }

        return result
    }
}
