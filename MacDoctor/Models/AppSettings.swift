//
//  MacDoctor/Models/AppSettings.swift
//  Mac Doctor
//
//  Value types, defaults, and UserDefaults keys for user preferences, menu bar
//  display, alert thresholds, launch at login, and Low Impact Mode.
//

import Foundation

enum RefreshIntervalOption: Int, CaseIterable, Identifiable, Sendable {
    case oneSecond = 1
    case twoSeconds = 2
    case fiveSeconds = 5

    var id: Self { self }

    var label: String { "\(rawValue)s" }

    var duration: Duration { .seconds(rawValue) }
}

enum MenuBarReadout: String, CaseIterable, Identifiable, Sendable {
    case none
    case cpu
    case temperature
    case network

    var id: Self { self }

    var label: String {
        switch self {
        case .none: "Icon"
        case .cpu: "CPU"
        case .temperature: "Temp"
        case .network: "Net"
        }
    }

    var accessibilityName: String {
        switch self {
        case .none: "Icon only"
        case .cpu: "CPU percentage"
        case .temperature: "Temperature"
        case .network: "Network speed"
        }
    }
}

enum MenuBarIconChoice: String, CaseIterable, Identifiable, Sendable {
    case stethoscope
    case vitals

    var id: Self { self }

    var symbolName: String {
        switch self {
        case .stethoscope: "stethoscope"
        case .vitals: "heart.text.square"
        }
    }

    var label: String {
        switch self {
        case .stethoscope: "Stethoscope"
        case .vitals: "Vitals"
        }
    }
}

// MARK: - Alerts & System integration status

enum AlertKind: String, Hashable, Sendable {
    case highCPU
    case highTemperature
    case memoryPressure
}

struct AlertEvent: Sendable, Equatable {
    let kind: AlertKind
    let severity: StatusTone
    let title: String
    let body: String
}

enum LoginItemStatus: Sendable, Equatable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable(String)

    var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .enabled: "Enabled"
        case .disabled: "Off"
        case .requiresApproval: "Needs approval"
        case .unavailable: "Unavailable"
        }
    }
}

enum NotificationPermissionStatus: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case unavailable

    var label: String {
        switch self {
        case .notDetermined: "Not requested"
        case .authorized: "Allowed"
        case .denied: "Denied in System Settings"
        case .unavailable: "Unavailable"
        }
    }
}

// MARK: - Persistence keys

enum AppSettingsKeys {
    static let refreshInterval = "refreshIntervalSeconds"
    static let menuBarReadout = "menuBarReadout"
    static let menuBarIcon = "menuBarIcon"
    static let temperatureUnit = TemperaturePreferences.unitKey
    static let cpuAlertThreshold = "cpuAlertThresholdPercent"
    static let temperatureAlertThreshold = TemperaturePreferences.alertThresholdKey
    static let memoryPressureAlert = "memoryPressureAlertEnabled"
    static let notificationsEnabled = "notificationsEnabled"
    static let lowImpactMode = "lowImpactModeEnabled"

    static let defaultCPUThresholdPercent: Double = 85
    static let cpuSustainedDurationSeconds: TimeInterval = 30
}
