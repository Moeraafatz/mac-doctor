//
//  MacDoctor/Models/StorageMetrics.swift
//  Mac Doctor
//
//  Immutable, Sendable models for the Safe Storage Cleaner and System Data
//  inspector. Only user-owned, regenerable caches, logs, and Trash can ever
//  be cleaned; personal folders and System Data hogs are read-only with
//  "Reveal in Finder".
//

import Foundation

enum CleanableCategoryKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case trash
    case xcodeCaches
    case developerCaches
    case appCaches
    case userLogs

    var id: Self { self }

    var title: String {
        switch self {
        case .trash: "Trash"
        case .xcodeCaches: "Xcode & Simulator Caches"
        case .developerCaches: "Developer Package Caches"
        case .appCaches: "Safe App Caches"
        case .userLogs: "User Logs & Crash Reports"
        }
    }

    var symbol: String {
        switch self {
        case .trash: "trash"
        case .xcodeCaches: "hammer"
        case .developerCaches: "shippingbox"
        case .appCaches: "tray.full"
        case .userLogs: "doc.text"
        }
    }

    var safetyNote: String {
        switch self {
        case .trash: "Items already moved to Trash"
        case .xcodeCaches: "DerivedData & simulator caches — rebuilt automatically"
        case .developerCaches: "Homebrew, pip, uv, npm, bun, SwiftPM download caches"
        case .appCaches: "Regenerable user caches (skips Apple system & iCloud caches)"
        case .userLogs: "Diagnostic logs & old crash reports"
        }
    }

    /// Safe caches are pre-selected; Trash defaults off until checked so users
    /// don't accidentally empty Trash without noticing.
    var selectedByDefault: Bool {
        self != .trash
    }
}

struct CleanableCategory: Identifiable, Sendable, Equatable {
    var id: CleanableCategoryKind { kind }
    let kind: CleanableCategoryKind
    let bytes: UInt64
    let itemCount: Int
    let primaryURL: URL
    let targetDirectories: [URL]

    var isEmpty: Bool { bytes == 0 && itemCount == 0 }
}

/// Read-only storage hog inside System Data (Application Support, Containers,
/// ~/.cache) or large Downloads (>200 MB) — never deleted automatically.
struct StorageInsightItem: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let locationLabel: String
    let url: URL
    let bytes: UInt64
}

struct StorageScanSnapshot: Sendable, Equatable {
    let categories: [CleanableCategory]
    let systemDataHogs: [StorageInsightItem]
    let largeDownloads: [StorageInsightItem]
    let localSnapshotCount: Int
    let totalDiskBytes: UInt64?
    let freeDiskBytes: UInt64?
    let purgeableBytes: UInt64?
    let scannedAt: Date

    var totalCleanableBytes: UInt64 {
        categories.reduce(0) { $0 &+ $1.bytes }
    }

    var usedDiskBytes: UInt64? {
        guard let totalDiskBytes, let freeDiskBytes, totalDiskBytes >= freeDiskBytes else { return nil }
        return totalDiskBytes - freeDiskBytes
    }
}

struct CleanResult: Sendable, Equatable {
    let freedBytes: UInt64
    let removedItems: Int
    let skippedItems: Int
    let date: Date
}
