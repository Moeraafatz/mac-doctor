//
//  MacDoctor/Services/StorageCleanerService.swift
//  Mac Doctor
//
//  Scans and safely cleans user-owned regenerable caches, logs, and Trash off
//  the main thread. Zero root privileges, zero shell `rm`, strict home-folder
//  path jail, symlink protection, and an explicit Apple system-cache denylist.
//

import Foundation

protocol StorageScanningAndCleaning: Sendable {
    func scan() async -> StorageScanSnapshot
    func clean(kinds: Set<CleanableCategoryKind>) async -> CleanResult
}

actor StorageCleanerService: StorageScanningAndCleaning {
    /// Subfolders of `~/Library/Caches` owned by Apple system services, iCloud,
    /// browsers, or Mac Doctor itself that must NEVER be touched.
    private static let protectedCacheNames: Set<String> = [
        "CloudKit",
        "FamilyCircle",
        "GeoServices",
        "PassKit",
        "com.apple.Safari",
        "com.apple.Spotlight",
        "com.apple.accountsd",
        "com.apple.bird",
        "com.apple.cloudd",
        "com.apple.helpd",
        "com.apple.iCloudHelper",
        "com.apple.nsurlsessiond",
        "com.apple.parsecd",
        "com.apple.proactive.eventtracker",
        "com.macdoctor.app"
    ]

    /// Caches handled by the dedicated `.developerCaches` category so they are
    /// not double-counted under `.appCaches`.
    private static let developerCacheNamesInLibraryCaches: Set<String> = [
        "Homebrew",
        "pip",
        "uv",
        "Yarn",
        "pnpm",
        "CocoaPods",
        "org.swift.swiftpm"
    ]

    private static let largeDownloadMinBytes: UInt64 = 200_000_000 // 200 MB

    private let homeURL: URL

    init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeURL = homeURL.standardizedFileURL
    }

    // MARK: - Scan

    func scan() async -> StorageScanSnapshot {
        let fm = FileManager.default
        let disk = readDiskCapacity()
        let snapshots = await countLocalSnapshots()

        var categories: [CleanableCategory] = []
        for kind in CleanableCategoryKind.allCases {
            let dirs = targetDirectories(for: kind)
            var totalBytes: UInt64 = 0
            var totalItems = 0

            for dir in dirs where fm.fileExists(atPath: dir.path) {
                let children = eligibleChildren(in: dir, kind: kind)
                totalItems += children.count
                for child in children {
                    totalBytes &+= allocatedSize(of: child)
                }
            }

            categories.append(CleanableCategory(
                kind: kind,
                bytes: totalBytes,
                itemCount: totalItems,
                primaryURL: dirs.first ?? homeURL,
                targetDirectories: dirs
            ))
        }

        let hogs = scanSystemDataHogs()
        let downloads = scanLargeDownloads()

        return StorageScanSnapshot(
            categories: categories,
            systemDataHogs: hogs,
            largeDownloads: downloads,
            localSnapshotCount: snapshots,
            totalDiskBytes: disk.total,
            freeDiskBytes: disk.free,
            purgeableBytes: disk.purgeable,
            scannedAt: .now
        )
    }

    // MARK: - Clean (strictly jailed)

    func clean(kinds: Set<CleanableCategoryKind>) async -> CleanResult {
        let fm = FileManager.default
        var freedBytes: UInt64 = 0
        var removedItems = 0
        var skippedItems = 0

        for kind in CleanableCategoryKind.allCases where kinds.contains(kind) {
            let dirs = targetDirectories(for: kind)
            for dir in dirs where fm.fileExists(atPath: dir.path) {
                let children = eligibleChildren(in: dir, kind: kind)
                for child in children {
                    guard Self.isSafeToDelete(child, insideAllowedRoot: dir, home: homeURL) else {
                        skippedItems += 1
                        continue
                    }

                    let itemSize = allocatedSize(of: child)
                    do {
                        try fm.removeItem(at: child)
                        freedBytes &+= itemSize
                        removedItems += 1
                    } catch {
                        // Locked or currently open cache files are skipped cleanly.
                        skippedItems += 1
                    }
                }
            }
        }

        AppLog.sensors.notice(
            "StorageCleanerService: freed \(freedBytes, privacy: .public) bytes (\(removedItems, privacy: .public) removed, \(skippedItems, privacy: .public) skipped)"
        )

        return CleanResult(
            freedBytes: freedBytes,
            removedItems: removedItems,
            skippedItems: skippedItems,
            date: .now
        )
    }

    // MARK: - Path rules & safety jail

    func targetDirectories(for kind: CleanableCategoryKind) -> [URL] {
        let lib = homeURL.appendingPathComponent("Library", isDirectory: true)
        let caches = lib.appendingPathComponent("Caches", isDirectory: true)

        switch kind {
        case .trash:
            return [homeURL.appendingPathComponent(".Trash", isDirectory: true)]

        case .xcodeCaches:
            let dev = lib.appendingPathComponent("Developer", isDirectory: true)
            return [
                dev.appendingPathComponent("Xcode/DerivedData", isDirectory: true),
                dev.appendingPathComponent("CoreSimulator/Caches", isDirectory: true),
                dev.appendingPathComponent("Xcode/UserData/Previews", isDirectory: true)
            ]

        case .developerCaches:
            return [
                caches.appendingPathComponent("Homebrew", isDirectory: true),
                caches.appendingPathComponent("uv", isDirectory: true),
                caches.appendingPathComponent("pip", isDirectory: true),
                caches.appendingPathComponent("Yarn", isDirectory: true),
                caches.appendingPathComponent("pnpm", isDirectory: true),
                caches.appendingPathComponent("CocoaPods", isDirectory: true),
                caches.appendingPathComponent("org.swift.swiftpm", isDirectory: true),
                homeURL.appendingPathComponent(".npm/_cacache", isDirectory: true),
                homeURL.appendingPathComponent(".bun/install/cache", isDirectory: true)
            ]

        case .appCaches:
            return [caches]

        case .userLogs:
            return [lib.appendingPathComponent("Logs", isDirectory: true)]
        }
    }

    private func eligibleChildren(in directory: URL, kind: CleanableCategoryKind) -> [URL] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else {
            return []
        }

        return contents.filter { url in
            let name = url.lastPathComponent
            if name == ".DS_Store" { return false }

            // Never traverse or delete symlinks inside cache folders.
            if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
               values.isSymbolicLink == true {
                return false
            }

            if kind == .appCaches {
                if Self.protectedCacheNames.contains(name) { return false }
                if Self.developerCacheNamesInLibraryCaches.contains(name) { return false }
                if name.hasPrefix("com.apple.") { return false }
            }

            return true
        }
    }

    /// Defense-in-depth path jail verified immediately before every delete.
    static func isSafeToDelete(
        _ candidate: URL,
        insideAllowedRoot root: URL,
        home: URL
    ) -> Bool {
        let stdHome = home.standardizedFileURL.path
        let stdRoot = root.standardizedFileURL.path
        let stdCandidate = candidate.standardizedFileURL.path

        guard !stdHome.isEmpty, stdHome != "/" else { return false }
        guard stdRoot.hasPrefix(stdHome + "/") else { return false }
        guard stdCandidate.hasPrefix(stdRoot + "/") else { return false }
        guard stdCandidate != stdRoot, stdCandidate != stdHome else { return false }
        guard !stdCandidate.contains("/../") else { return false }

        // Ensure candidate is not a symbolic link pointing outside the jail.
        if let values = try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            return false
        }

        return true
    }

    // MARK: - Read-only System Data & Large Downloads inspection

    private func scanSystemDataHogs() -> [StorageInsightItem] {
        let fm = FileManager.default
        let roots: [(label: String, url: URL)] = [
            ("App Support", homeURL.appendingPathComponent("Library/Application Support", isDirectory: true)),
            ("Containers", homeURL.appendingPathComponent("Library/Containers", isDirectory: true)),
            ("~/.cache", homeURL.appendingPathComponent(".cache", isDirectory: true)),
            ("Developer", homeURL.appendingPathComponent("Library/Developer", isDirectory: true))
        ]

        var items: [StorageInsightItem] = []

        for root in roots where fm.fileExists(atPath: root.url.path) {
            guard let children = try? fm.contentsOfDirectory(
                at: root.url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for child in children {
                if let vals = try? child.resourceValues(forKeys: [.isSymbolicLinkKey]),
                   vals.isSymbolicLink == true {
                    continue
                }
                let size = allocatedSize(of: child)
                // Only surface notable consumers (>= 150 MB) to keep the list actionable.
                guard size >= 150_000_000 else { continue }
                items.append(StorageInsightItem(
                    id: child.path,
                    name: child.lastPathComponent,
                    locationLabel: root.label,
                    url: child,
                    bytes: size
                ))
            }
        }

        return items
            .sorted { $0.bytes > $1.bytes }
            .prefix(8)
            .map { $0 }
    }

    private func scanLargeDownloads() -> [StorageInsightItem] {
        let fm = FileManager.default
        let downloads = homeURL.appendingPathComponent("Downloads", isDirectory: true)
        guard let children = try? fm.contentsOfDirectory(
            at: downloads,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var items: [StorageInsightItem] = []
        for child in children {
            if let vals = try? child.resourceValues(forKeys: [.isSymbolicLinkKey]),
               vals.isSymbolicLink == true {
                continue
            }
            let size = allocatedSize(of: child)
            guard size >= Self.largeDownloadMinBytes else { continue }
            items.append(StorageInsightItem(
                id: child.path,
                name: child.lastPathComponent,
                locationLabel: "Downloads",
                url: child,
                bytes: size
            ))
        }

        return items
            .sorted { $0.bytes > $1.bytes }
            .prefix(6)
            .map { $0 }
    }

    // MARK: - Sizing & APFS helpers

    private func allocatedSize(of url: URL) -> UInt64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]

        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isSymbolicLink == true { return 0 }

        if values.isRegularFile == true {
            return UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }

        guard values.isDirectory == true else { return 0 }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: UInt64 = 0
        var visited = 0
        let maxFilesPerEntry = 60_000

        for case let fileURL as URL in enumerator {
            visited += 1
            if visited > maxFilesPerEntry { break }

            guard let res = try? fileURL.resourceValues(forKeys: keys) else { continue }
            if res.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if res.isRegularFile == true {
                total &+= UInt64(res.totalFileAllocatedSize ?? res.fileAllocatedSize ?? res.fileSize ?? 0)
            }
        }

        return total
    }

    private func readDiskCapacity() -> (total: UInt64?, free: UInt64?, purgeable: UInt64?) {
        let root = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        guard let values = try? root.resourceValues(forKeys: keys) else {
            return (nil, nil, nil)
        }
        let total = values.volumeTotalCapacity.map { UInt64(max(0, $0)) }
        let regularFree = values.volumeAvailableCapacity.map { UInt64(max(0, $0)) }
        let importantFree = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }

        let purgeable: UInt64?
        if let importantFree, let regularFree, importantFree > regularFree {
            purgeable = importantFree - regularFree
        } else {
            purgeable = nil
        }

        return (total, regularFree, purgeable)
    }

    private func countLocalSnapshots() async -> Int {
        let outcome = await SubprocessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/tmutil"),
            arguments: ["listlocalsnapshots", "/"],
            timeout: .seconds(3)
        )
        guard case .exited(let output) = outcome, output.exitCode == 0 else { return 0 }
        return output.stdout
            .split(whereSeparator: \.isNewline)
            .filter { $0.contains("com.apple.") }
            .count
    }
}
