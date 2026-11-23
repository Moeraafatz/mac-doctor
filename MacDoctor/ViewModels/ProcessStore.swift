//
//  MacDoctor/ViewModels/ProcessStore.swift
//  Mac Doctor
//
//  Main-actor view model for the Processes (Task Manager) tab. Owns search,
//  sorting, icon caching, and the two-step Quit / Force Quit confirmation flow.
//  All libproc and nettop work happens inside `ProcessService`'s actor.
//

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class ProcessStore {
    private(set) var snapshot: ProcessSnapshot = .empty
    private(set) var isRefreshing = false
    private(set) var quitAttemptedPIDs: Set<pid_t> = []
    private(set) var lastFeedback: ProcessActionResult?
    /// Memoized sorted & grouped process list — recomputed only when snapshot,
    /// sortKey, searchText, or groupByApp changes (never on hover/expand redraws).
    private(set) var groupedProcesses: [ProcessGroup] = []

    var sortKey: ProcessSortKey = .cpu {
        didSet { if oldValue != sortKey { rebuildGroupedProcesses() } }
    }
    var searchText: String = "" {
        didSet { if oldValue != searchText { rebuildGroupedProcesses() } }
    }
    var groupByApp: Bool = true {
        didSet { if oldValue != groupByApp { rebuildGroupedProcesses() } }
    }
    var expandedGroupIDs: Set<String> = []
    var pendingAction: PendingProcessAction?

    private let sampler: any ProcessSampling
    private let controller: any ProcessControlling
    private let activeInterval: Duration

    @ObservationIgnored private var isPopoverVisible = false
    @ObservationIgnored private var isProcessesTabVisible = false
    @ObservationIgnored private var isLowImpactActive = false
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    private let defaultProcessIcon: NSImage
    @ObservationIgnored private var feedbackDismissTask: Task<Void, Never>?

    init(
        sampler: any ProcessSampling = ProcessService(),
        controller: any ProcessControlling = ProcessController(),
        activeInterval: Duration = .seconds(2),
        backgroundInterval: Duration = .seconds(4),
        initialSnapshot: ProcessSnapshot = .empty
    ) {
        self.sampler = sampler
        self.controller = controller
        self.activeInterval = activeInterval
        self.snapshot = initialSnapshot

        let fallback = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
            ?? NSWorkspace.shared.icon(for: .unixExecutable)
        fallback.size = NSSize(width: 22, height: 22)
        self.defaultProcessIcon = fallback
        rebuildGroupedProcesses()
    }

    var filteredProcesses: [ProcessEntry] {
        computeFilteredProcesses()
    }

    private func rebuildGroupedProcesses() {
        groupedProcesses = computeGroupedProcesses()
    }

    private func computeFilteredProcesses() -> [ProcessEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [ProcessEntry]
        if query.isEmpty {
            base = snapshot.processes
        } else {
            base = snapshot.processes.filter { entry in
                entry.name.localizedCaseInsensitiveContains(query)
                    || entry.executableName.localizedCaseInsensitiveContains(query)
                    || (entry.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false)
                    || String(entry.pid).contains(query)
            }
        }

        return base.sorted { lhs, rhs in
            switch sortKey {
            case .cpu:
                if abs(lhs.cpuPercent - rhs.cpuPercent) > 0.05 {
                    return lhs.cpuPercent > rhs.cpuPercent
                }
            case .memory:
                if lhs.memoryBytes != rhs.memoryBytes {
                    return lhs.memoryBytes > rhs.memoryBytes
                }
            case .energy:
                if abs(lhs.energy.sortValue - rhs.energy.sortValue) > 0.05 {
                    return lhs.energy.sortValue > rhs.energy.sortValue
                }
            case .network:
                if abs(lhs.totalNetworkRate - rhs.totalNetworkRate) > 1 {
                    return lhs.totalNetworkRate > rhs.totalNetworkRate
                }
                if lhs.totalNetworkCumulative != rhs.totalNetworkCumulative {
                    return lhs.totalNetworkCumulative > rhs.totalNetworkCumulative
                }
            }

            if abs(lhs.cpuPercent - rhs.cpuPercent) > 0.05 {
                return lhs.cpuPercent > rhs.cpuPercent
            }
            if lhs.memoryBytes != rhs.memoryBytes {
                return lhs.memoryBytes > rhs.memoryBytes
            }
            return lhs.pid < rhs.pid
        }
    }

    /// Groups processes that share an enclosing `.app` bundle (parent app +
    /// embedded helpers/renderers) into collapsible aggregate rows.
    private func computeGroupedProcesses() -> [ProcessGroup] {
        let sorted = computeFilteredProcesses()
        guard groupByApp else {
            return sorted.map { singleGroup(for: $0) }
        }

        var buckets: [String: [ProcessEntry]] = [:]
        var standalone: [ProcessEntry] = []

        for entry in sorted {
            if let rootPath = entry.rootAppBundlePath {
                buckets[rootPath, default: []].append(entry)
            } else {
                standalone.append(entry)
            }
        }

        var groups: [ProcessGroup] = standalone.map { singleGroup(for: $0) }
        groups.reserveCapacity(groups.count + buckets.count)

        for (rootPath, members) in buckets {
            if members.count == 1, let only = members.first {
                groups.append(singleGroup(for: only))
                continue
            }

            let appTitle = URL(fileURLWithPath: rootPath).deletingPathExtension().lastPathComponent
            let primary = members.first(where: {
                $0.bundleURL?.path == rootPath && $0.isGUIApp
            }) ?? members.first(where: { $0.isGUIApp }) ?? members[0]

            let totalCPU = members.reduce(0.0) { $0 + $1.cpuPercent }
            let totalMem = members.reduce(UInt64(0)) { $0 &+ $1.memoryBytes }

            var measuredSum = 0.0
            var hasMeasured = false
            var estimatedSum = 0.0
            var hasEstimated = false
            for member in members {
                switch member.energy {
                case .measuredWatts(let w):
                    measuredSum += w
                    hasMeasured = true
                case .estimated(let s):
                    estimatedSum += s
                    hasEstimated = true
                case .unavailable:
                    break
                }
            }
            let combinedEnergy: ProcessEnergy = hasMeasured
                ? .measuredWatts(measuredSum)
                : (hasEstimated ? .estimated(estimatedSum) : .unavailable)

            let netInValues = members.compactMap(\.networkBytesInPerSec)
            let netOutValues = members.compactMap(\.networkBytesOutPerSec)
            let netIn = netInValues.isEmpty ? nil : netInValues.reduce(0, +)
            let netOut = netOutValues.isEmpty ? nil : netOutValues.reduce(0, +)
            let netCumulative = members.reduce(UInt64(0)) { $0 &+ $1.totalNetworkCumulative }

            groups.append(ProcessGroup(
                id: rootPath,
                name: primary.isGUIApp ? primary.name : appTitle,
                primaryEntry: primary,
                members: members,
                totalCPUPercent: totalCPU,
                totalMemoryBytes: totalMem,
                totalEnergy: combinedEnergy,
                totalNetworkBytesInPerSec: netIn,
                totalNetworkBytesOutPerSec: netOut,
                totalNetworkCumulative: netCumulative,
                hasOffender: members.contains(where: \.isOffender)
            ))
        }

        return groups.sorted { lhs, rhs in
            switch sortKey {
            case .cpu:
                if abs(lhs.totalCPUPercent - rhs.totalCPUPercent) > 0.05 {
                    return lhs.totalCPUPercent > rhs.totalCPUPercent
                }
            case .memory:
                if lhs.totalMemoryBytes != rhs.totalMemoryBytes {
                    return lhs.totalMemoryBytes > rhs.totalMemoryBytes
                }
            case .energy:
                if abs(lhs.totalEnergy.sortValue - rhs.totalEnergy.sortValue) > 0.05 {
                    return lhs.totalEnergy.sortValue > rhs.totalEnergy.sortValue
                }
            case .network:
                if abs(lhs.totalNetworkRate - rhs.totalNetworkRate) > 1 {
                    return lhs.totalNetworkRate > rhs.totalNetworkRate
                }
                if lhs.totalNetworkCumulative != rhs.totalNetworkCumulative {
                    return lhs.totalNetworkCumulative > rhs.totalNetworkCumulative
                }
            }

            if abs(lhs.totalCPUPercent - rhs.totalCPUPercent) > 0.05 {
                return lhs.totalCPUPercent > rhs.totalCPUPercent
            }
            return lhs.primaryEntry.pid < rhs.primaryEntry.pid
        }
    }

    func toggleGroupExpanded(_ id: String) {
        if expandedGroupIDs.contains(id) {
            expandedGroupIDs.remove(id)
        } else {
            expandedGroupIDs.insert(id)
        }
    }

    private func singleGroup(for entry: ProcessEntry) -> ProcessGroup {
        ProcessGroup(
            id: "pid:\(entry.pid)",
            name: entry.name,
            primaryEntry: entry,
            members: [entry],
            totalCPUPercent: entry.cpuPercent,
            totalMemoryBytes: entry.memoryBytes,
            totalEnergy: entry.energy,
            totalNetworkBytesInPerSec: entry.networkBytesInPerSec,
            totalNetworkBytesOutPerSec: entry.networkBytesOutPerSec,
            totalNetworkCumulative: entry.totalNetworkCumulative,
            hasOffender: entry.isOffender
        )
    }

    func setPopoverVisible(_ visible: Bool) {
        guard isPopoverVisible != visible else { return }
        isPopoverVisible = visible
        if !visible {
            iconCache.removeAll(keepingCapacity: false)
        }
        updatePollingState()
    }

    func setProcessesTabVisible(_ visible: Bool) {
        guard isProcessesTabVisible != visible else { return }
        isProcessesTabVisible = visible
        updatePollingState()
    }

    func setLowImpactActive(_ active: Bool) {
        isLowImpactActive = active
    }

    private func updatePollingState() {
        let shouldPoll = isPopoverVisible && isProcessesTabVisible
        if shouldPoll {
            guard pollingTask == nil else { return }
            pollingTask = Task(priority: .utility) { [weak self] in
                await self?.run()
            }
        } else {
            pollingTask?.cancel()
            pollingTask = nil
        }
    }

    func run() async {
        while !Task.isCancelled {
            await refreshOnce()

            let sleepDuration = isLowImpactActive ? activeInterval * 2 : activeInterval
            do {
                try await Task.sleep(for: sleepDuration, tolerance: .milliseconds(400))
            } catch {
                return
            }
        }
    }

    func refreshOnce() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let next = await sampler.sample(includeNetwork: isProcessesTabVisible && isPopoverVisible)
        guard !Task.isCancelled else { return }

        snapshot = next
        rebuildGroupedProcesses()

        let livePIDs = Set(next.processes.map(\.pid))
        quitAttemptedPIDs.formIntersection(livePIDs)
    }

    // MARK: - Actions & two-step confirmations

    func hasAttemptedQuit(_ entry: ProcessEntry) -> Bool {
        quitAttemptedPIDs.contains(entry.pid)
    }

    func requestPrimaryAction(for entry: ProcessEntry) {
        switch entry.policy {
        case .blocked:
            return
        case .relaunchOnly:
            pendingAction = PendingProcessAction(entry: entry, kind: .relaunchFinder)
        case .allowed:
            let kind: ProcessActionKind = quitAttemptedPIDs.contains(entry.pid) ? .forceQuit : .quit
            pendingAction = PendingProcessAction(entry: entry, kind: kind)
        }
    }

    func requestQuit(for entry: ProcessEntry) {
        guard entry.policy.isKillable else { return }
        pendingAction = PendingProcessAction(entry: entry, kind: .quit)
    }

    func requestForceQuit(for entry: ProcessEntry) {
        guard entry.policy.isKillable else { return }
        // Require graceful Quit / SIGTERM first so Force Quit / SIGKILL is
        // always a second confirmation after an initial attempt.
        let kind: ProcessActionKind = quitAttemptedPIDs.contains(entry.pid) ? .forceQuit : .quit
        pendingAction = PendingProcessAction(entry: entry, kind: kind)
    }

    func cancelPendingAction() {
        pendingAction = nil
    }

    func confirmPendingAction() async {
        guard let action = pendingAction else { return }
        pendingAction = nil

        let result: ProcessActionResult
        switch action.kind {
        case .quit:
            result = await controller.quit(action.entry)
            if !result.isError {
                quitAttemptedPIDs.insert(action.entry.pid)
            }
        case .forceQuit:
            result = await controller.forceQuit(action.entry)
        case .relaunchFinder:
            result = await controller.relaunchFinder()
        }

        showFeedback(result)

        try? await Task.sleep(for: .milliseconds(400))
        await refreshOnce()
    }

    func dismissFeedback() {
        feedbackDismissTask?.cancel()
        lastFeedback = nil
    }

    // MARK: - Icon cache

    func icon(for entry: ProcessEntry) -> NSImage {
        let key: String
        let filePath: String?

        if let bundlePath = entry.bundleURL?.path {
            key = bundlePath
            filePath = bundlePath
        } else if let execPath = entry.executablePath,
                  let appPath = enclosingAppBundlePath(for: execPath) {
            key = appPath
            filePath = appPath
        } else if let execPath = entry.executablePath {
            key = execPath
            filePath = execPath
        } else {
            return defaultProcessIcon
        }

        if let cached = iconCache[key] {
            return cached
        }

        guard let filePath, FileManager.default.fileExists(atPath: filePath) else {
            return defaultProcessIcon
        }

        if iconCache.count >= 64 {
            iconCache.removeAll(keepingCapacity: true)
        }

        let raw = NSWorkspace.shared.icon(forFile: filePath)
        let image = Self.rasterizeThumbnail(raw, pointSize: 22)
        iconCache[key] = image
        return image
    }

    /// Flattens a multi-resolution `.icns` NSImage (which may embed a 1024×1024
    /// representation weighing ~4 MB) into a single crisp @2x bitmap (~8 KB).
    private static func rasterizeThumbnail(_ source: NSImage, pointSize: CGFloat) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        return NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)
            return true
        }
    }

    private func enclosingAppBundlePath(for executablePath: String) -> String? {
        guard let range = executablePath.range(of: ".app/") else { return nil }
        return String(executablePath[..<range.upperBound].dropLast())
    }

    private func showFeedback(_ result: ProcessActionResult) {
        feedbackDismissTask?.cancel()
        lastFeedback = result
        feedbackDismissTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            lastFeedback = nil
        }
    }
}
