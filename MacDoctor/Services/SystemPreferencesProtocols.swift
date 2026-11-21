//
//  MacDoctor/Services/SystemPreferencesProtocols.swift
//  Mac Doctor
//
//  Protocols for Launch at Login (SMAppService) and alert notifications
//  (UserNotifications) so SettingsStore and VitalsStore remain testable.
//

import Foundation

protocol LaunchAtLoginManaging: Sendable {
    func status() -> LoginItemStatus
    func setEnabled(_ enabled: Bool) -> Result<LoginItemStatus, LaunchAtLoginError>
}

struct LaunchAtLoginError: Error, Sendable, Equatable {
    let message: String
}

protocol AlertNotifying: Sendable {
    func permissionStatus() async -> NotificationPermissionStatus
    func requestAuthorization() async -> NotificationPermissionStatus
    func send(_ event: AlertEvent) async
    func sendTestNotification() async -> Bool
}
