//
//  MacDoctor/ViewModels/SettingsStore.swift
//  Mac Doctor
//
//  Main-actor preferences store backed by UserDefaults, LaunchAtLoginManaging
//  (SMAppService.mainApp), and AlertNotifying (UserNotifications).
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class SettingsStore {
    var refreshInterval: RefreshIntervalOption {
        didSet { defaults.set(refreshInterval.rawValue, forKey: AppSettingsKeys.refreshInterval) }
    }

    var menuBarReadout: MenuBarReadout {
        didSet { defaults.set(menuBarReadout.rawValue, forKey: AppSettingsKeys.menuBarReadout) }
    }

    var menuBarIcon: MenuBarIconChoice {
        didSet { defaults.set(menuBarIcon.rawValue, forKey: AppSettingsKeys.menuBarIcon) }
    }

    var temperatureUnit: TemperatureUnit {
        didSet { defaults.set(temperatureUnit.rawValue, forKey: AppSettingsKeys.temperatureUnit) }
    }

    /// CPU % threshold (default 85%). Must be sustained for 30s to trigger.
    var cpuAlertThresholdPercent: Double {
        didSet {
            let clamped = min(max(cpuAlertThresholdPercent, 50), 100)
            if clamped != cpuAlertThresholdPercent {
                cpuAlertThresholdPercent = clamped
                return
            }
            defaults.set(clamped, forKey: AppSettingsKeys.cpuAlertThreshold)
        }
    }

    /// Temperature alert threshold stored in °C (default 95 °C).
    var temperatureAlertThresholdCelsius: Double {
        didSet {
            let clamped = min(max(temperatureAlertThresholdCelsius, 60), 110)
            if clamped != temperatureAlertThresholdCelsius {
                temperatureAlertThresholdCelsius = clamped
                return
            }
            defaults.set(clamped, forKey: AppSettingsKeys.temperatureAlertThreshold)
        }
    }

    var memoryPressureAlertEnabled: Bool {
        didSet { defaults.set(memoryPressureAlertEnabled, forKey: AppSettingsKeys.memoryPressureAlert) }
    }

    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: AppSettingsKeys.notificationsEnabled) }
    }

    var lowImpactModeEnabled: Bool {
        didSet { defaults.set(lowImpactModeEnabled, forKey: AppSettingsKeys.lowImpactMode) }
    }

    private(set) var loginItemStatus: LoginItemStatus = .disabled
    private(set) var loginItemError: String?
    private(set) var notificationPermission: NotificationPermissionStatus = .notDetermined
    private(set) var testNotificationFeedback: String?

    private let defaults: UserDefaults
    private let loginManager: any LaunchAtLoginManaging
    private let notifier: any AlertNotifying

    init(
        defaults: UserDefaults = .standard,
        loginManager: any LaunchAtLoginManaging = LaunchAtLoginService(),
        notifier: any AlertNotifying = AlertNotificationService()
    ) {
        self.defaults = defaults
        self.loginManager = loginManager
        self.notifier = notifier

        let storedInterval = defaults.integer(forKey: AppSettingsKeys.refreshInterval)
        self.refreshInterval = RefreshIntervalOption(rawValue: storedInterval) ?? .twoSeconds

        let storedReadout = defaults.string(forKey: AppSettingsKeys.menuBarReadout) ?? ""
        self.menuBarReadout = MenuBarReadout(rawValue: storedReadout) ?? .none

        let storedIcon = defaults.string(forKey: AppSettingsKeys.menuBarIcon) ?? ""
        self.menuBarIcon = MenuBarIconChoice(rawValue: storedIcon) ?? .stethoscope

        let storedUnit = defaults.string(forKey: AppSettingsKeys.temperatureUnit) ?? ""
        self.temperatureUnit = TemperatureUnit(rawValue: storedUnit) ?? .celsius

        if defaults.object(forKey: AppSettingsKeys.cpuAlertThreshold) != nil {
            self.cpuAlertThresholdPercent = min(max(defaults.double(forKey: AppSettingsKeys.cpuAlertThreshold), 50), 100)
        } else {
            self.cpuAlertThresholdPercent = AppSettingsKeys.defaultCPUThresholdPercent
        }

        if defaults.object(forKey: AppSettingsKeys.temperatureAlertThreshold) != nil {
            self.temperatureAlertThresholdCelsius = min(
                max(defaults.double(forKey: AppSettingsKeys.temperatureAlertThreshold), 60),
                110
            )
        } else {
            self.temperatureAlertThresholdCelsius = TemperaturePreferences.defaultAlertThreshold
        }

        if defaults.object(forKey: AppSettingsKeys.memoryPressureAlert) != nil {
            self.memoryPressureAlertEnabled = defaults.bool(forKey: AppSettingsKeys.memoryPressureAlert)
        } else {
            self.memoryPressureAlertEnabled = true
        }

        self.notificationsEnabled = defaults.bool(forKey: AppSettingsKeys.notificationsEnabled)

        if defaults.object(forKey: AppSettingsKeys.lowImpactMode) != nil {
            self.lowImpactModeEnabled = defaults.bool(forKey: AppSettingsKeys.lowImpactMode)
        } else {
            self.lowImpactModeEnabled = true
        }

        self.loginItemStatus = loginManager.status()
    }

    // MARK: - Polling cadence (Low Impact Mode)

    /// Returns the active polling interval in seconds. When Low Impact Mode is
    /// enabled and the Mac is running on battery, polling slows down to save
    /// power (at least 5s, or 2× the configured interval).
    func effectivePollingSeconds(isOnBattery: Bool) -> Int {
        if lowImpactModeEnabled && isOnBattery {
            return max(refreshInterval.rawValue * 2, 5)
        }
        return refreshInterval.rawValue
    }

    func effectivePollingDuration(isOnBattery: Bool) -> Duration {
        .seconds(effectivePollingSeconds(isOnBattery: isOnBattery))
    }

    // MARK: - Launch at login

    func refreshSystemStatuses() async {
        loginItemStatus = loginManager.status()
        notificationPermission = await notifier.permissionStatus()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = nil
        switch loginManager.setEnabled(enabled) {
        case .success(let updated):
            loginItemStatus = updated
        case .failure(let error):
            loginItemStatus = loginManager.status()
            loginItemError = error.message
        }
    }

    func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Notifications

    func toggleNotifications(_ enabled: Bool) async {
        notificationsEnabled = enabled
        guard enabled else { return }

        let current = await notifier.permissionStatus()
        if current == .notDetermined {
            notificationPermission = await notifier.requestAuthorization()
        } else {
            notificationPermission = current
        }
    }

    func requestNotificationPermission() async {
        notificationPermission = await notifier.requestAuthorization()
    }

    func sendTestNotification() async {
        testNotificationFeedback = nil
        let sent = await notifier.sendTestNotification()
        testNotificationFeedback = sent
            ? "Test notification sent."
            : "Enable notifications for Mac Doctor in System Settings first."
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func resetDefaults() {
        refreshInterval = .twoSeconds
        menuBarReadout = .none
        menuBarIcon = .stethoscope
        temperatureUnit = .celsius
        cpuAlertThresholdPercent = AppSettingsKeys.defaultCPUThresholdPercent
        temperatureAlertThresholdCelsius = TemperaturePreferences.defaultAlertThreshold
        memoryPressureAlertEnabled = true
        lowImpactModeEnabled = true
    }
}
