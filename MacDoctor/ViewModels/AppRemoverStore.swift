//
//  MacDoctor/ViewModels/AppRemoverStore.swift
//  Mac Doctor
//
//  Main-actor view model for the App Remover sub-mode inside the Clean tab.
//  App discovery, leftover scanning, and Trash moves execute off the main
//  thread in `AppRemoverService`.
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppRemoverStore {
    private(set) var apps: [InstalledApp] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var preparingAppID: String?
    private(set) var isRemoving = false
    private(set) var lastResult: AppRemovalResult?

    var searchText = ""
    var sortOrder: AppSortOrder = .size
    var pendingPlan: AppRemovalPlan?
    var selectedItemIDs: Set<String> = []

    private let service: any AppRemoving
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var planTask: Task<Void, Never>?
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]

    init(service: any AppRemoving = AppRemoverService()) {
        self.service = service
    }

    var filteredApps: [InstalledApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched: [InstalledApp]
        if query.isEmpty {
            matched = apps
        } else {
            matched = apps.filter { app in
                app.name.lowercased().contains(query)
                    || (app.bundleIdentifier?.lowercased().contains(query) ?? false)
            }
        }

        switch sortOrder {
        case .size:
            return matched.sorted { lhs, rhs in
                if lhs.appSizeBytes != rhs.appSizeBytes {
                    return lhs.appSizeBytes > rhs.appSizeBytes
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        case .name:
            return matched.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    var totalInstalledBytes: UInt64 {
        apps.reduce(0) { $0 &+ $1.appSizeBytes }
    }

    var selectedPlanItems: [AppRemovalItem] {
        guard let pendingPlan else { return [] }
        return pendingPlan.items.filter { selectedItemIDs.contains($0.id) }
    }

    var selectedPlanBytes: UInt64 {
        selectedPlanItems.reduce(0) { $0 &+ $1.bytes }
    }

    var canConfirmRemoval: Bool {
        !isRemoving && !selectedPlanItems.isEmpty
    }

    func loadIfNeeded() {
        guard !hasLoaded, !isLoading else { return }
        reload()
    }

    func reload() {
        guard !isRemoving else { return }
        loadTask?.cancel()
        isLoading = true

        loadTask = Task {
            let discovered = await service.listInstalledApps()
            guard !Task.isCancelled else { return }
            apps = discovered
            hasLoaded = true
            isLoading = false
        }
    }

    func icon(for app: InstalledApp) -> NSImage {
        if let cached = iconCache[app.id] {
            return cached
        }
        if iconCache.count >= 64 {
            iconCache.removeAll(keepingCapacity: true)
        }
        let raw = NSWorkspace.shared.icon(forFile: app.url.path)
        let thumb = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            raw.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)
            return true
        }
        iconCache[app.id] = thumb
        return thumb
    }

    func trimMemory() {
        iconCache.removeAll(keepingCapacity: false)
    }

    func prepareRemoval(for app: InstalledApp) {
        guard !isRemoving else { return }
        planTask?.cancel()
        preparingAppID = app.id

        planTask = Task {
            let plan = await service.buildRemovalPlan(for: app)
            guard !Task.isCancelled else { return }
            selectedItemIDs = Set(plan.items.map(\.id))
            pendingPlan = plan
            preparingAppID = nil
        }
    }

    func toggleItem(_ id: String) {
        if selectedItemIDs.contains(id) {
            selectedItemIDs.remove(id)
        } else {
            selectedItemIDs.insert(id)
        }
    }

    func cancelRemoval() {
        pendingPlan = nil
        selectedItemIDs = []
    }

    func confirmRemoval(onFinished: (() -> Void)? = nil) {
        guard let plan = pendingPlan, canConfirmRemoval else { return }
        let chosen = selectedItemIDs
        pendingPlan = nil
        selectedItemIDs = []
        isRemoving = true

        Task {
            let result = await service.remove(plan: plan, selectedItemIDs: chosen)
            lastResult = result
            isRemoving = false
            reload()
            onFinished?()
        }
    }

    func revealInFinder(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func dismissResult() {
        lastResult = nil
    }
}
