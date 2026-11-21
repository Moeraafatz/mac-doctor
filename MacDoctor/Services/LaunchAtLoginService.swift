//
//  MacDoctor/Services/LaunchAtLoginService.swift
//  Mac Doctor
//
//  Manages Launch at Login via Apple's `SMAppService.mainApp`. No deprecated
//  login-item helpers, no launch agents written to disk, and no privileges.
//

import Foundation
import ServiceManagement

struct LaunchAtLoginService: LaunchAtLoginManaging {
    func status() -> LoginItemStatus {
        map(SMAppService.mainApp.status)
    }

    func setEnabled(_ enabled: Bool) -> Result<LoginItemStatus, LaunchAtLoginError> {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                AppLog.lifecycle.info("LaunchAtLoginService: registered SMAppService.mainApp")
            } else {
                try SMAppService.mainApp.unregister()
                AppLog.lifecycle.info("LaunchAtLoginService: unregistered SMAppService.mainApp")
            }
            return .success(map(SMAppService.mainApp.status))
        } catch {
            let message = error.localizedDescription
            AppLog.lifecycle.error("LaunchAtLoginService: failed to \(enabled ? "register" : "unregister", privacy: .public): \(message, privacy: .public)")
            return .failure(LaunchAtLoginError(message: message))
        }
    }

    private func map(_ raw: SMAppService.Status) -> LoginItemStatus {
        switch raw {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable("App bundle must be in Applications to register")
        @unknown default:
            return .unavailable("Unknown login item state")
        }
    }
}
