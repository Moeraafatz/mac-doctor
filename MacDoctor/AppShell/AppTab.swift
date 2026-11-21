//
//  MacDoctor/AppShell/AppTab.swift
//  Mac Doctor
//
//  Top-level destinations of the popover. Five primary tabs live in the
//  segmented tab bar (`Overview`, `Temps`, `Processes`, `Network`, `Clean`);
//  `Settings` opens from the header gear button (⌘,).
//

import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case overview
    case temperatures
    case processes
    case network
    case cleaner
    case settings

    static let tabBarCases: [AppTab] = [
        .overview,
        .temperatures,
        .processes,
        .network,
        .cleaner
    ]

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .temperatures: "Temps"
        case .processes: "Procs"
        case .network: "Network"
        case .cleaner: "Clean"
        case .settings: "Settings"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .temperatures: "Temperatures"
        case .processes: "Processes"
        case .cleaner: "Storage Cleaner"
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .overview: "speedometer"
        case .temperatures: "thermometer"
        case .processes: "list.bullet.rectangle"
        case .network: "network"
        case .cleaner: "sparkles"
        case .settings: "gearshape"
        }
    }

    var emptyTitle: String {
        switch self {
        case .overview: "Your Mac, at a glance"
        case .temperatures: "Thermal sensors"
        case .processes: "Process control"
        case .network: "Network health"
        case .cleaner: "Storage cleaner"
        case .settings: "Make it yours"
        }
    }

    var emptyMessage: String {
        switch self {
        case .overview:
            "CPU, GPU, memory, disk, battery, thermal state and live network rates will appear here."
        case .temperatures:
            "Per-sensor CPU, GPU, SoC, battery and SSD temperatures will appear here when available."
        case .processes:
            "See what is using CPU, memory, energy and network, and stop misbehaving apps safely."
        case .network:
            "Throughput, speed tests, ping, Wi-Fi details and recent results will appear here."
        case .cleaner:
            "Scan and safely clean user caches, developer caches, logs, and Trash."
        case .settings:
            "Refresh rate, menu bar readout, temperature units, alerts and launch at login will live here."
        }
    }

    var nextStep: String {
        switch self {
        case .overview: "Live system vitals"
        case .temperatures: "Sensor bridge"
        case .processes: "Process control"
        case .network: "Speed test and Wi-Fi"
        case .cleaner: "Safe disk cleanup"
        case .settings: "Preferences"
        }
    }
}
