//
//  MacDoctor/Models/AppRemoverMetrics.swift
//  Mac Doctor
//
//  Immutable, Sendable models for the App Remover (deep uninstaller) inside
//  the Clean tab. Strictly scoped to user-installed third-party and App Store
//  apps in /Applications and ~/Applications — never built-in macOS apps or
//  Mac Doctor itself.
//

import Foundation

enum InstalledAppSource: String, Sendable, Equatable {
    case appStore = "App Store"
    case downloaded = "Downloaded"
}

enum AppSortOrder: String, CaseIterable, Identifiable, Sendable {
    case size
    case name

    var id: Self { self }

    var label: String {
        switch self {
        case .size: "Largest"
        case .name: "A–Z"
        }
    }
}

struct InstalledApp: Identifiable, Sendable, Equatable {
    var id: String { url.path }
    let name: String
    let bundleIdentifier: String?
    let version: String?
    let url: URL
    let appSizeBytes: UInt64
    let source: InstalledAppSource
    var aliasURLs: [URL] = []
}

enum LeftoverKind: String, Sendable, Equatable {
    case appBundle = "Application"
    case applicationSupport = "App Support"
    case caches = "Caches"
    case containers = "Container"
    case groupContainers = "Group Container"
    case preferences = "Preferences"
    case savedState = "Saved State"
    case logs = "Logs"
    case httpStorage = "HTTP Storage"
    case webKit = "WebKit"
    case applicationScripts = "App Scripts"
    case launchAgents = "Launch Agent"
}

struct AppRemovalItem: Identifiable, Sendable, Equatable {
    var id: String { url.path }
    let url: URL
    let displayName: String
    let kind: LeftoverKind
    let bytes: UInt64
}

struct AppRemovalPlan: Identifiable, Sendable, Equatable {
    var id: String { app.id }
    let app: InstalledApp
    let items: [AppRemovalItem]
    let isRunning: Bool

    var totalBytes: UInt64 {
        items.reduce(0) { $0 &+ $1.bytes }
    }
}

struct AppRemovalResult: Sendable, Equatable {
    let appName: String
    let trashedCount: Int
    let freedBytes: UInt64
    let failedItems: [AppRemovalItem]
    let appBundleNeedsFinder: Bool
    let appBundleURL: URL
}
