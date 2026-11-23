//
//  MacDoctor/Services/AppRemoverService.swift
//  Mac Doctor
//
//  Discovers user-installed apps in /Applications and ~/Applications (excluding
//  all built-in macOS apps and Mac Doctor itself), locates their leftover files
//  strictly inside ~/Library, and moves selected items to Trash safely with
//  zero root privileges.
//

import AppKit
import Foundation

protocol AppRemoving: Sendable {
    func listInstalledApps() async -> [InstalledApp]
    func buildRemovalPlan(for app: InstalledApp) async -> AppRemovalPlan
    func remove(plan: AppRemovalPlan, selectedItemIDs: Set<String>) async -> AppRemovalResult
}

actor AppRemoverService: AppRemoving {
    /// Core macOS Apple apps that can NEVER appear in App Remover even if
    /// firmlinked into /Applications.
    private static let protectedBundleIDs: Set<String> = [
        "com.macdoctor.app",
        "com.apple.Safari",
        "com.apple.AppStore",
        "com.apple.finder",
        "com.apple.systempreferences",
        "com.apple.Terminal",
        "com.apple.ActivityMonitor",
        "com.apple.DiskUtility",
        "com.apple.Console",
        "com.apple.keychainaccess",
        "com.apple.MigrationAssistant",
        "com.apple.ScreenSharing",
        "com.apple.QuickTimePlayerX",
        "com.apple.Preview",
        "com.apple.TextEdit",
        "com.apple.Photos",
        "com.apple.mail",
        "com.apple.MobileSMS",
        "com.apple.FaceTime",
        "com.apple.Music",
        "com.apple.TV",
        "com.apple.Podcasts",
        "com.apple.iBooksX",
        "com.apple.Maps",
        "com.apple.Notes",
        "com.apple.reminders",
        "com.apple.iCal",
        "com.apple.AddressBook",
        "com.apple.weather",
        "com.apple.clock",
        "com.apple.calculator",
        "com.apple.stocks",
        "com.apple.home",
        "com.apple.freeform",
        "com.apple.Passwords",
        "com.apple.VoiceMemos",
        "com.apple.Shortcuts",
        "com.apple.Automator",
        "com.apple.ScriptEditor2"
    ]

    /// Standard uninstaller helper stubs inside vendor app folders (e.g. Cinema 4D's
    /// `uninstall.app` or `Creative Cloud Uninstaller.app`) that should not clutter
    /// the installed apps list.
    private static func isUninstallerStub(_ url: URL) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        return stem == "uninstall" || stem.contains("uninstaller")
    }

    /// Broad vendor or generic folder names that must NEVER be matched by name
    /// in ~/Library so removing one app cannot affect sibling apps from the same vendor.
    private static let genericFolderNames: Set<String> = [
        "apple", "adobe", "microsoft", "google", "mozilla", "jetbrains",
        "autodesk", "maxon", "cache", "caches", "logs", "data", "app", "system"
    ]

    private let homeURL: URL
    private let searchRoots: [URL]

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        searchRoots: [URL]? = nil
    ) {
        self.homeURL = homeURL.standardizedFileURL
        self.searchRoots = searchRoots ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeURL.standardizedFileURL.appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    // MARK: - List eligible user-installed apps

    func listInstalledApps() async -> [InstalledApp] {
        let fm = FileManager.default
        var byPath: [String: InstalledApp] = [:]

        func considerCandidate(_ candidateURL: URL) {
            let stdCandidate = candidateURL.standardizedFileURL
            let vals = try? stdCandidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isSymlink = vals?.isSymbolicLink == true

            let bundleURL: URL
            var aliasURL: URL?

            if isSymlink {
                let resolved = stdCandidate.resolvingSymlinksInPath().standardizedFileURL
                guard resolved.pathExtension.lowercased() == "app" else { return }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue else { return }
                bundleURL = resolved
                aliasURL = stdCandidate
            } else {
                guard stdCandidate.pathExtension.lowercased() == "app" else { return }
                guard vals?.isDirectory == true else { return }
                bundleURL = stdCandidate
            }

            guard !Self.isUninstallerStub(bundleURL) else { return }

            let info = readBundleInfo(at: bundleURL)
            guard !Self.isProtectedApp(
                url: bundleURL,
                bundleIdentifier: info.bundleID,
                isAppStore: info.isAppStore,
                homeURL: homeURL
            ) else {
                return
            }

            if var existing = byPath[bundleURL.path] {
                if let aliasURL, !existing.aliasURLs.contains(aliasURL) {
                    existing.aliasURLs.append(aliasURL)
                    byPath[bundleURL.path] = existing
                }
                return
            }

            let size = allocatedSize(of: bundleURL)
            byPath[bundleURL.path] = InstalledApp(
                name: info.displayName,
                bundleIdentifier: info.bundleID,
                version: info.version,
                url: bundleURL,
                appSizeBytes: size,
                source: info.isAppStore ? .appStore : .downloaded,
                aliasURLs: aliasURL.map { [$0] } ?? []
            )
        }

        func scanDirectory(_ directory: URL, depth: Int) {
            guard let contents = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                return
            }

            for entry in contents {
                let stdEntry = entry.standardizedFileURL
                let vals = try? stdEntry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let isSymlink = vals?.isSymbolicLink == true
                let isDir = vals?.isDirectory == true

                if isSymlink || stdEntry.pathExtension.lowercased() == "app" {
                    considerCandidate(stdEntry)
                } else if isDir, depth < 1 {
                    // Never descend into /Applications/Utilities (built-in macOS tools
                    // and background Adobe/vendor runtime daemons live there).
                    if stdEntry.path == "/Applications/Utilities" { continue }
                    scanDirectory(stdEntry, depth: depth + 1)
                }
            }
        }

        for root in searchRoots where fm.fileExists(atPath: root.path) {
            scanDirectory(root, depth: 0)
        }

        return byPath.values.sorted { $0.appSizeBytes > $1.appSizeBytes }
    }

    // MARK: - Discover exact leftovers inside ~/Library

    func buildRemovalPlan(for app: InstalledApp) async -> AppRemovalPlan {
        let isRunning = await checkIfRunning(app)
        var items: [AppRemovalItem] = [
            AppRemovalItem(
                url: app.url,
                displayName: app.url.lastPathComponent,
                kind: .appBundle,
                bytes: app.appSizeBytes
            )
        ]

        // Include any /Applications alias symlinks pointing to this app (e.g. Riot Client).
        for aliasURL in app.aliasURLs {
            items.append(AppRemovalItem(
                url: aliasURL,
                displayName: "\(aliasURL.lastPathComponent) (Alias)",
                kind: .appBundle,
                bytes: 0
            ))
        }

        let leftovers = discoverLeftovers(for: app)
        items.append(contentsOf: leftovers)

        return AppRemovalPlan(app: app, items: items, isRunning: isRunning)
    }

    // MARK: - Safe Trash removal

    func remove(plan: AppRemovalPlan, selectedItemIDs: Set<String>) async -> AppRemovalResult {
        let app = plan.app
        let info = readBundleInfo(at: app.url)
        guard !Self.isProtectedApp(
            url: app.url,
            bundleIdentifier: info.bundleID ?? app.bundleIdentifier,
            isAppStore: info.isAppStore,
            homeURL: homeURL
        ) else {
            AppLog.sensors.notice("AppRemoverService: refused protected app \(app.name, privacy: .public)")
            return AppRemovalResult(
                appName: app.name,
                trashedCount: 0,
                freedBytes: 0,
                failedItems: plan.items,
                appBundleNeedsFinder: false,
                appBundleURL: app.url
            )
        }

        let selected = plan.items.filter { selectedItemIDs.contains($0.id) }
        guard !selected.isEmpty else {
            return AppRemovalResult(
                appName: app.name,
                trashedCount: 0,
                freedBytes: 0,
                failedItems: [],
                appBundleNeedsFinder: false,
                appBundleURL: app.url
            )
        }

        // If the app is currently running, ask it to quit gracefully first.
        if plan.isRunning {
            await terminateRunningApp(app)
            try? await Task.sleep(for: .milliseconds(600))
        }

        let fm = FileManager.default
        var trashedCount = 0
        var freedBytes: UInt64 = 0
        var failed: [AppRemovalItem] = []
        var appBundleNeedsFinder = false

        for item in selected {
            guard Self.isSafeRemovalTarget(item.url, kind: item.kind, homeURL: homeURL) else {
                failed.append(item)
                continue
            }

            guard fm.fileExists(atPath: item.url.path) else { continue }

            do {
                try fm.trashItem(at: item.url, resultingItemURL: nil)
                trashedCount += 1
                freedBytes &+= item.bytes
            } catch {
                AppLog.sensors.error(
                    "AppRemoverService: failed to trash \(item.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                failed.append(item)
                if item.kind == .appBundle {
                    appBundleNeedsFinder = true
                }
            }
        }

        AppLog.sensors.notice(
            "AppRemoverService: removed \(app.name, privacy: .public) (\(trashedCount, privacy: .public) trashed, \(failed.count, privacy: .public) failed)"
        )

        return AppRemovalResult(
            appName: app.name,
            trashedCount: trashedCount,
            freedBytes: freedBytes,
            failedItems: failed,
            appBundleNeedsFinder: appBundleNeedsFinder,
            appBundleURL: app.url
        )
    }

    // MARK: - Safety guards (pure, unit-testable)

    static func isProtectedApp(
        url: URL,
        bundleIdentifier: String?,
        isAppStore: Bool,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let stdPath = url.standardizedFileURL.path
        let resolvedPath = url.resolvingSymlinksInPath().path
        let userApps = homeURL.standardizedFileURL.appendingPathComponent("Applications").path

        // Never allow anything inside /System (including firmlinks and Cryptexes).
        if stdPath.hasPrefix("/System/") || resolvedPath.hasPrefix("/System/") {
            return true
        }

        // Must live inside /Applications, ~/Applications, or /Users/Shared
        // (third-party apps symlinked from /Applications such as Riot Client).
        let inSystemApps = stdPath.hasPrefix("/Applications/")
        let inUserApps = stdPath.hasPrefix(userApps + "/")
        let inSharedApps = stdPath.hasPrefix("/Users/Shared/")
        guard inSystemApps || inUserApps || inSharedApps else { return true }

        // Never allow top-level apps sitting directly in /Applications/Utilities.
        if stdPath.hasPrefix("/Applications/Utilities/") {
            let rel = String(stdPath.dropFirst("/Applications/Utilities/".count))
            if !rel.contains("/") {
                return true
            }
        }

        let filename = url.deletingPathExtension().lastPathComponent
        if filename == "Mac Doctor" || filename == "MacDoctor" { return true }

        if let bid = bundleIdentifier {
            if protectedBundleIDs.contains(bid) { return true }
            // Block all non-App-Store Apple bundles (system / preinstalled utilities).
            if bid.hasPrefix("com.apple.") && !isAppStore { return true }
        }

        return false
    }

    static func isSafeRemovalTarget(
        _ url: URL,
        kind: LeftoverKind,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let stdPath = url.standardizedFileURL.path
        let stdHome = homeURL.standardizedFileURL.path
        guard !stdPath.contains("/../") else { return false }

        let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true

        switch kind {
        case .appBundle:
            let userApps = stdHome + "/Applications/"
            let inApps = stdPath.hasPrefix("/Applications/")
            let inUserApps = stdPath.hasPrefix(userApps)
            let inSharedApps = stdPath.hasPrefix("/Users/Shared/")
            let resolved = url.resolvingSymlinksInPath().path
            guard !resolved.hasPrefix("/System/") else { return false }

            if isSymlink {
                // Only allow removing app alias symlinks inside /Applications or ~/Applications.
                guard inApps || inUserApps else { return false }
                return resolved.lowercased().hasSuffix(".app")
            }

            guard url.pathExtension.lowercased() == "app" else { return false }
            if stdPath.hasPrefix("/Applications/Utilities/") {
                let rel = String(stdPath.dropFirst("/Applications/Utilities/".count))
                if !rel.contains("/") { return false }
            }
            return inApps || inUserApps || inSharedApps

        default:
            // Never follow or delete symlinks inside ~/Library.
            guard !isSymlink else { return false }
            let libraryPrefix = stdHome + "/Library/"
            guard stdPath.hasPrefix(libraryPrefix) else { return false }
            // Ensure we never target a top-level ~/Library/<Folder> itself.
            let relative = String(stdPath.dropFirst(libraryPrefix.count))
            let parts = relative.split(separator: "/")
            return parts.count >= 2
        }
    }

    // MARK: - Leftover scanner (strict exact matching)

    private func discoverLeftovers(for app: InstalledApp) -> [AppRemovalItem] {
        let fm = FileManager.default
        let lib = homeURL.appendingPathComponent("Library", isDirectory: true)

        let rawBundleID = app.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleID = (rawBundleID?.isEmpty == false) ? rawBundleID : nil
        let bundleLower = bundleID?.lowercased()

        let appName = app.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleFileName = app.url.deletingPathExtension().lastPathComponent
        let exactNames: Set<String> = Set(
            [appName, bundleFileName]
                .map { $0.lowercased() }
                .filter { $0.count >= 3 && !Self.genericFolderNames.contains($0) }
        )

        var found: [AppRemovalItem] = []
        var seen: Set<String> = []

        func addIfMatch(url: URL, kind: LeftoverKind) {
            let std = url.standardizedFileURL
            guard !seen.contains(std.path) else { return }
            guard Self.isSafeRemovalTarget(std, kind: kind, homeURL: homeURL) else { return }
            seen.insert(std.path)
            found.append(AppRemovalItem(
                url: std,
                displayName: std.lastPathComponent,
                kind: kind,
                bytes: allocatedSize(of: std)
            ))
        }

        // Helper for directories whose direct children match bundleID or exact app name.
        let namedDirectories: [(subpath: String, kind: LeftoverKind, allowNameMatch: Bool)] = [
            ("Application Support", .applicationSupport, true),
            ("Caches", .caches, true),
            ("Logs", .logs, true),
            ("Containers", .containers, false),
            ("HTTPStorages", .httpStorage, false),
            ("WebKit", .webKit, false),
            ("Application Scripts", .applicationScripts, false)
        ]

        for spec in namedDirectories {
            let dir = lib.appendingPathComponent(spec.subpath, isDirectory: true)
            guard let children = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for child in children {
                let nameLower = child.lastPathComponent.lowercased()
                let matchesBundle = bundleLower.map { nameLower == $0 } ?? false
                let matchesName = spec.allowNameMatch && exactNames.contains(nameLower)
                if matchesBundle || matchesName {
                    addIfMatch(url: child, kind: spec.kind)
                }
            }
        }

        // Vendor-nested exact app folders (e.g. ~/Library/Application Support/Adobe/Adobe Photoshop 2027
        // or ~/Library/Caches/Adobe/Photoshop 2027) — NEVER targets the parent vendor folder itself.
        let vendorPrefixes = ["adobe", "maxon", "microsoft", "google"]
        for vendor in vendorPrefixes {
            let prefix = vendor + " "
            let matchingAppNames = exactNames.filter { $0.hasPrefix(prefix) }
            guard !matchingAppNames.isEmpty else { continue }

            var nestedNames = Set(matchingAppNames)
            for fullName in matchingAppNames {
                let stripped = String(fullName.dropFirst(prefix.count))
                if stripped.count >= 4 && !Self.genericFolderNames.contains(stripped) {
                    nestedNames.insert(stripped)
                }
            }

            for (subpath, kind) in [
                ("Application Support", LeftoverKind.applicationSupport),
                ("Caches", LeftoverKind.caches),
                ("Logs", LeftoverKind.logs),
                ("Preferences", LeftoverKind.preferences)
            ] {
                let vendorDir = lib.appendingPathComponent(subpath, isDirectory: true)
                    .appendingPathComponent(vendor.capitalized, isDirectory: true)
                guard let children = try? fm.contentsOfDirectory(
                    at: vendorDir,
                    includingPropertiesForKeys: [.isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continue
                }
                for child in children {
                    let childLower = child.lastPathComponent.lowercased()
                    if nestedNames.contains(childLower) {
                        addIfMatch(url: child, kind: kind)
                    }
                }
            }
        }

        // Adobe/vendor preference settings directories directly under ~/Library/Preferences
        // (e.g. ~/Library/Preferences/Adobe Photoshop 2027 Settings).
        let prefsRoot = lib.appendingPathComponent("Preferences", isDirectory: true)
        if let children = try? fm.contentsOfDirectory(at: prefsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for child in children {
                let lower = child.lastPathComponent.lowercased()
                if exactNames.contains(where: { lower == "\($0) settings" }) {
                    addIfMatch(url: child, kind: .preferences)
                }
            }
        }

        // Saved Application State: <bundleID>.savedState
        if let bundleLower {
            let savedDir = lib.appendingPathComponent("Saved Application State", isDirectory: true)
            if let children = try? fm.contentsOfDirectory(at: savedDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for child in children where child.lastPathComponent.lowercased() == "\(bundleLower).savedstate" {
                    addIfMatch(url: child, kind: .savedState)
                }
            }

            // Preferences & Preferences/ByHost: <bundleID>.plist or <bundleID>.*.plist
            for prefSubpath in ["Preferences", "Preferences/ByHost"] {
                let prefDir = lib.appendingPathComponent(prefSubpath, isDirectory: true)
                if let children = try? fm.contentsOfDirectory(at: prefDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for child in children {
                        let lower = child.lastPathComponent.lowercased()
                        guard lower.hasSuffix(".plist") else { continue }
                        if lower == "\(bundleLower).plist" || lower.hasPrefix("\(bundleLower).") {
                            addIfMatch(url: child, kind: .preferences)
                        }
                    }
                }
            }

            // LaunchAgents: <bundleID>.plist or <bundleID>.*.plist
            let agentsDir = lib.appendingPathComponent("LaunchAgents", isDirectory: true)
            if let children = try? fm.contentsOfDirectory(at: agentsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for child in children {
                    let lower = child.lastPathComponent.lowercased()
                    guard lower.hasSuffix(".plist") else { continue }
                    if lower == "\(bundleLower).plist" || lower.hasPrefix("\(bundleLower).") {
                        addIfMatch(url: child, kind: .launchAgents)
                    }
                }
            }

            // Group Containers: <TeamID>.<exact bundleID> (strict suffix match only)
            let groupDir = lib.appendingPathComponent("Group Containers", isDirectory: true)
            if let children = try? fm.contentsOfDirectory(at: groupDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for child in children {
                    let lower = child.lastPathComponent.lowercased()
                    if lower == bundleLower || lower.hasSuffix(".\(bundleLower)") {
                        addIfMatch(url: child, kind: .groupContainers)
                    }
                }
            }
        }

        return found.sorted { $0.bytes > $1.bytes }
    }

    // MARK: - Bundle metadata, running check & sizing

    private func readBundleInfo(at appURL: URL) -> (displayName: String, bundleID: String?, version: String?, isAppStore: Bool) {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        let receiptURL = appURL.appendingPathComponent("Contents/_MASReceipt/receipt")
        let isAppStore = FileManager.default.fileExists(atPath: receiptURL.path)

        let fallbackName = appURL.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return (fallbackName, nil, nil, isAppStore)
        }

        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? fallbackName
        let bundleID = plist["CFBundleIdentifier"] as? String
        let version = (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String)

        return (name.isEmpty ? fallbackName : name, bundleID, version, isAppStore)
    }

    @MainActor
    private func checkIfRunning(_ app: InstalledApp) -> Bool {
        if let bid = app.bundleIdentifier,
           !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty {
            return true
        }
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.standardizedFileURL == app.url.standardizedFileURL
        }
    }

    @MainActor
    private func terminateRunningApp(_ app: InstalledApp) {
        if let bid = app.bundleIdentifier {
            for running in NSRunningApplication.runningApplications(withBundleIdentifier: bid) {
                _ = running.terminate()
            }
            return
        }
        for running in NSWorkspace.shared.runningApplications
        where running.bundleURL?.standardizedFileURL == app.url.standardizedFileURL {
            _ = running.terminate()
        }
    }

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

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: UInt64 = 0
        var visited = 0
        let maxFiles = 60_000

        for case let fileURL as URL in enumerator {
            visited += 1
            if visited > maxFiles { break }

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
}
