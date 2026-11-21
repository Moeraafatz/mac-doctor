//
//  MacDoctor/Services/AlertNotificationService.swift
//  Mac Doctor
//
//  Delivers optional local macOS notifications via UserNotifications when a
//  configured alert threshold is crossed. Enforces a per-alert cooldown so
//  sustained load never spams Notification Center.
//

import Foundation
import UserNotifications

actor AlertNotificationService: AlertNotifying {
    private let cooldown: TimeInterval
    private var lastSent: [AlertKind: Date] = [:]
    private let delegateBridge = NotificationForegroundDelegate()
    private var didConfigureDelegate = false

    init(cooldownSeconds: TimeInterval = 300) {
        self.cooldown = max(cooldownSeconds, 10)
    }

    private var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func permissionStatus() async -> NotificationPermissionStatus {
        guard isAppBundle else { return .unavailable }
        configureDelegateIfNeeded()

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unavailable
        }
    }

    func requestAuthorization() async -> NotificationPermissionStatus {
        guard isAppBundle else { return .unavailable }
        configureDelegateIfNeeded()

        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            AppLog.lifecycle.info("AlertNotificationService: authorization granted=\(granted, privacy: .public)")
            return await permissionStatus()
        } catch {
            AppLog.lifecycle.error("AlertNotificationService: authorization failed: \(error.localizedDescription, privacy: .public)")
            return await permissionStatus()
        }
    }

    func send(_ event: AlertEvent) async {
        guard isAppBundle else { return }
        configureDelegateIfNeeded()

        let now = Date()
        if let previous = lastSent[event.kind], now.timeIntervalSince(previous) < cooldown {
            return
        }

        guard await permissionStatus() == .authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.macdoctor.alert.\(event.kind.rawValue)",
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            lastSent[event.kind] = now
            AppLog.lifecycle.notice("AlertNotificationService: delivered \(event.kind.rawValue, privacy: .public) alert")
        } catch {
            AppLog.lifecycle.error("AlertNotificationService: failed to deliver alert: \(error.localizedDescription, privacy: .public)")
        }
    }

    func sendTestNotification() async -> Bool {
        guard isAppBundle else { return false }
        configureDelegateIfNeeded()
        guard await permissionStatus() == .authorized else { return false }

        let content = UNMutableNotificationContent()
        content.title = "Mac Doctor Alerts Active"
        content.body = "You'll be notified here when CPU, temperature, or memory pressure crosses your thresholds."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.macdoctor.alert.test.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            AppLog.lifecycle.error("AlertNotificationService: test notification failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func configureDelegateIfNeeded() {
        guard !didConfigureDelegate else { return }
        didConfigureDelegate = true
        UNUserNotificationCenter.current().delegate = delegateBridge
    }
}

/// Ensures local alert banners appear even while the Mac Doctor popover is open.
private final class NotificationForegroundDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
