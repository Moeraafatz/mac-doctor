//
//  MacDoctor/Services/ConnectionInfoService.swift
//  Mac Doctor
//
//  Reads active interface type (Wi-Fi / Ethernet), local IP, router IP, and
//  CoreWLAN radio metrics (RSSI, noise, channel, band, SSID) off the main
//  thread. Zero network traffic is generated.
//

import CoreLocation
import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

actor ConnectionInfoService: ConnectionInfoSampling {
    private let locationManager = CLLocationManager()

    func sample() async -> ConnectionInfo {
        let global = Self.readPrimaryRoute()
        let primaryInterface = global.primaryInterface

        let wifiClient = CWWiFiClient.shared()
        let wifiInterfaceNames = Set(wifiClient.interfaceNames() ?? [])
        let cwInterface: CWInterface? = {
            if let primaryInterface, wifiInterfaceNames.contains(primaryInterface) {
                return wifiClient.interface(withName: primaryInterface)
            }
            return wifiClient.interface()
        }()

        let effectiveInterfaceName = primaryInterface ?? cwInterface?.interfaceName
        let kind = Self.classifyInterface(
            name: effectiveInterfaceName,
            wifiNames: wifiInterfaceNames
        )

        let localIP = effectiveInterfaceName.flatMap { Self.readLocalIP(for: $0) }
        let wifiDetails: WiFiDetails? = {
            guard kind == .wifi || (effectiveInterfaceName == nil && cwInterface != nil),
                  let cwInterface
            else {
                return nil
            }
            return readWiFiDetails(from: cwInterface)
        }()

        let resolvedKind: NetworkInterfaceKind
        if effectiveInterfaceName == nil && localIP == nil && wifiDetails == nil {
            resolvedKind = .disconnected
        } else {
            resolvedKind = kind
        }

        return ConnectionInfo(
            interfaceName: effectiveInterfaceName,
            interfaceKind: resolvedKind,
            localIP: localIP,
            routerIP: global.routerIP,
            dnsServers: Self.readDNSServers(),
            vpnInterface: Self.detectActiveVPNInterface(),
            wifi: wifiDetails,
            capturedAt: .now
        )
    }

    // MARK: - CoreWLAN

    private func readWiFiDetails(from interface: CWInterface) -> WiFiDetails? {
        let rssiRaw = interface.rssiValue()
        let noiseRaw = interface.noiseMeasurement()
        let channel = interface.wlanChannel()
        let txRate = interface.transmitRate()
        let rawSSID = interface.ssid()

        let isAssociated = channel != nil || rssiRaw != 0 || (rawSSID != nil && !(rawSSID?.isEmpty ?? true))
        guard isAssociated else { return nil }

        let ssidStatus: SSIDStatus
        if let rawSSID, !rawSSID.isEmpty {
            ssidStatus = .available(rawSSID)
        } else if locationManager.authorizationStatus != .authorizedAlways {
            ssidStatus = .hiddenPermissionNeeded
        } else {
            ssidStatus = .unavailable
        }

        let band: String? = channel.flatMap { ch in
            switch ch.channelBand {
            case .band2GHz: "2.4 GHz"
            case .band5GHz: "5 GHz"
            case .band6GHz: "6 GHz"
            case .bandUnknown: nil
            @unknown default: nil
            }
        }

        let widthMHz: Int? = channel.flatMap { ch in
            switch ch.channelWidth {
            case .width20MHz: 20
            case .width40MHz: 40
            case .width80MHz: 80
            case .width160MHz: 160
            case .widthUnknown: nil
            @unknown default: nil
            }
        }

        return WiFiDetails(
            ssidStatus: ssidStatus,
            rssi: rssiRaw != 0 ? rssiRaw : nil,
            noise: noiseRaw != 0 ? noiseRaw : nil,
            channelNumber: channel.map { $0.channelNumber },
            channelBand: band,
            channelWidthMHz: widthMHz,
            transmitRateMbps: txRate > 0 ? txRate : nil
        )
    }

    // MARK: - SystemConfiguration (primary interface & router IP)

    private static func readDNSServers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "com.macdoctor.app" as CFString, nil, nil),
              let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let servers = dns["ServerAddresses"] as? [String]
        else {
            return []
        }
        return servers
    }

    /// Detects an active VPN / WireGuard / Tailscale tunnel (`utun*` with a
    /// non-link-local IPv4 or IPv6 address and UP+RUNNING flags).
    private static func detectActiveVPNInterface() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return nil
        }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") else {
                continue
            }
            let flags = entry.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_RUNNING) != 0,
                  let addr = entry.pointee.ifa_addr
            else {
                continue
            }
            let family = Int32(addr.pointee.sa_family)
            if family == AF_INET {
                return name
            }
        }
        return nil
    }

    private static func readPrimaryRoute() -> (primaryInterface: String?, routerIP: String?) {
        guard let store = SCDynamicStoreCreate(nil, "com.macdoctor.app" as CFString, nil, nil) else {
            return (nil, nil)
        }

        if let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            let iface = ipv4["PrimaryInterface"] as? String
            let router = ipv4["Router"] as? String
            if iface != nil || router != nil {
                return (iface, router)
            }
        }

        if let ipv6 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString) as? [String: Any] {
            let iface = ipv6["PrimaryInterface"] as? String
            let router = ipv6["Router"] as? String
            return (iface, router)
        }

        return (nil, nil)
    }

    private static func classifyInterface(
        name: String?,
        wifiNames: Set<String>
    ) -> NetworkInterfaceKind {
        guard let name else { return .disconnected }
        if wifiNames.contains(name) {
            return .wifi
        }

        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for iface in all {
                guard let bsdName = SCNetworkInterfaceGetBSDName(iface) as String?,
                      bsdName == name
                else {
                    continue
                }
                if let type = SCNetworkInterfaceGetInterfaceType(iface) as String? {
                    if type == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                        return .wifi
                    }
                    if type == (kSCNetworkInterfaceTypeEthernet as String) {
                        return .ethernet
                    }
                }
            }
        }

        return name.hasPrefix("en") ? .ethernet : .other
    }

    // MARK: - getifaddrs (local IP for primary interface)

    private static func readLocalIP(for interfaceName: String) -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return nil
        }
        defer { freeifaddrs(first) }

        var ipv6Fallback: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first

        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }

            let name = String(cString: entry.pointee.ifa_name)
            guard name == interfaceName, let addr = entry.pointee.ifa_addr else { continue }

            let family = Int32(addr.pointee.sa_family)
            if family == AF_INET {
                if let ip = numericAddress(from: addr, length: socklen_t(addr.pointee.sa_len)) {
                    return ip
                }
            } else if family == AF_INET6, ipv6Fallback == nil {
                if let ip = numericAddress(from: addr, length: socklen_t(addr.pointee.sa_len)),
                   !ip.hasPrefix("fe80:") {
                    ipv6Fallback = ip
                }
            }
        }

        return ipv6Fallback
    }

    private static func numericAddress(
        from address: UnsafePointer<sockaddr>,
        length: socklen_t
    ) -> String? {
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address,
            length,
            &hostBuffer,
            socklen_t(hostBuffer.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else { return nil }
        let bytes = hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
