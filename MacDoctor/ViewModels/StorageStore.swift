//
//  MacDoctor/ViewModels/StorageStore.swift
//  Mac Doctor
//
//  Main-actor view model for the Safe Storage Cleaner tab. Scanning and
//  cleaning execute off the main thread in `StorageCleanerService`.
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class StorageStore {
    private(set) var snapshot: StorageScanSnapshot?
    private(set) var isScanning = false
    private(set) var isCleaning = false
    private(set) var lastCleanResult: CleanResult?

    var selectedKinds: Set<CleanableCategoryKind> = Set(
        CleanableCategoryKind.allCases.filter(\.selectedByDefault)
    )
    var showCleanConfirmation = false

    private let service: any StorageScanningAndCleaning
    private var scanTask: Task<Void, Never>?

    init(service: any StorageScanningAndCleaning = StorageCleanerService()) {
        self.service = service
    }

    var selectedCategories: [CleanableCategory] {
        guard let snapshot else { return [] }
        return snapshot.categories.filter { selectedKinds.contains($0.kind) && !$0.isEmpty }
    }

    var selectedBytes: UInt64 {
        selectedCategories.reduce(0) { $0 &+ $1.bytes }
    }

    var canClean: Bool {
        !isScanning && !isCleaning && !selectedCategories.isEmpty
    }

    func scanIfNeeded() {
        guard snapshot == nil, !isScanning else { return }
        startScan()
    }

    func startScan() {
        guard !isCleaning else { return }
        scanTask?.cancel()
        isScanning = true

        scanTask = Task {
            let result = await service.scan()
            guard !Task.isCancelled else { return }
            snapshot = result
            isScanning = false
        }
    }

    func toggle(_ kind: CleanableCategoryKind) {
        if selectedKinds.contains(kind) {
            selectedKinds.remove(kind)
        } else {
            selectedKinds.insert(kind)
        }
    }

    func requestClean() {
        guard canClean else { return }
        showCleanConfirmation = true
    }

    func confirmClean(onFinished: (() -> Void)? = nil) {
        guard canClean else { return }
        showCleanConfirmation = false
        isCleaning = true

        let kindsToClean = Set(selectedCategories.map(\.kind))
        Task {
            let result = await service.clean(kinds: kindsToClean)
            lastCleanResult = result
            isCleaning = false
            startScan()
            onFinished?()
        }
    }

    func revealInFinder(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func dismissCleanResult() {
        lastCleanResult = nil
    }
}
