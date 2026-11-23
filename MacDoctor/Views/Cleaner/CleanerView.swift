//
//  MacDoctor/Views/Cleaner/CleanerView.swift
//  Mac Doctor
//
//  Safe Storage Cleaner, System Data Inspector, and Deep App Remover styled in
//  Black Liquid Glass with crisp White hierarchy. Cleans only user-owned
//  regenerable caches, logs, and Trash, or moves third-party / App Store apps
//  and their exact ~/Library leftovers to Trash behind explicit confirmation.
//

import SwiftUI

enum CleanerMode: String, CaseIterable, Identifiable {
    case storage
    case apps

    var id: Self { self }

    var title: String {
        switch self {
        case .storage: "Storage"
        case .apps: "Apps"
        }
    }

    var symbol: String {
        switch self {
        case .storage: "sparkles"
        case .apps: "square.grid.2x2"
        }
    }
}

struct CleanerView: View {
    @Bindable var store: StorageStore
    @Bindable var appRemover: AppRemoverStore
    var initialMode: CleanerMode = .storage
    var onDiskChanged: (() -> Void)? = nil

    @State private var mode: CleanerMode = .storage
    @State private var didApplyInitialMode = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            modeSwitcher

            switch mode {
            case .storage:
                storageContent
            case .apps:
                AppRemoverView(store: appRemover, onDiskChanged: onDiskChanged)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            if !didApplyInitialMode {
                mode = initialMode
                didApplyInitialMode = true
            }
            if mode == .storage {
                store.scanIfNeeded()
            } else {
                appRemover.loadIfNeeded()
            }
        }
        .sheet(isPresented: $store.showCleanConfirmation) {
            CleanConfirmationSheet(
                categories: store.selectedCategories,
                totalBytes: store.selectedBytes,
                onCancel: { store.showCleanConfirmation = false },
                onConfirm: {
                    store.confirmClean(onFinished: onDiskChanged)
                }
            )
        }
    }

    private var modeSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(CleanerMode.allCases) { item in
                let isSelected = mode == item
                Button {
                    withAnimation(reduceMotion ? nil : AppMotion.snappy) {
                        mode = item
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 10, weight: .semibold))
                        Text(item.title)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.68))
                    .frame(maxWidth: .infinity)
                    .frame(height: 25)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                                .fill(Color.white)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background { ObsidianCardBackground(cornerRadius: 10) }
    }

    private var storageContent: some View {
        VStack(spacing: 8) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    diskHeroCard

                    if let result = store.lastCleanResult {
                        cleanResultBanner(result)
                    }

                    safeCleanupSection

                    if let snap = store.snapshot, !snap.systemDataHogs.isEmpty {
                        insightSection(
                            title: "What's in System Data",
                            subtitle: "Read-only · inspect before removing",
                            icon: "internaldrive.fill",
                            items: snap.systemDataHogs
                        )
                    }

                    if let snap = store.snapshot, !snap.largeDownloads.isEmpty {
                        insightSection(
                            title: "Large Downloads (>200 MB)",
                            subtitle: "Read-only · Reveal in Finder",
                            icon: "arrow.down.circle",
                            items: snap.largeDownloads
                        )
                    }
                }
                .padding(.bottom, 4)
            }

            if store.snapshot != nil {
                cleanFooterBar
            }
        }
    }

    // MARK: - Disk Hero Card

    private var diskHeroCard: some View {
        let snap = store.snapshot
        let total = snap?.totalDiskBytes ?? 0
        let used = snap?.usedDiskBytes ?? 0
        let free = snap?.freeDiskBytes ?? 0
        let reclaimable = snap?.totalCleanableBytes ?? 0

        let usedFraction = total > 0 ? min(max(Double(used) / Double(total), 0), 1) : 0
        let cleanableFraction = total > 0 ? min(max(Double(reclaimable) / Double(total), 0), usedFraction) : 0
        let keepFraction = max(0, usedFraction - cleanableFraction)

        return GlassSurface(cornerRadius: 18, contentPadding: 13) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MACINTOSH HD")
                            .font(AppFont.micro)
                            .tracking(0.9)
                            .foregroundStyle(AppColors.accentGlow.opacity(0.9))

                        if let snap, let freeBytes = snap.freeDiskBytes, let totalBytes = snap.totalDiskBytes {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text("\(MetricFormat.disk(freeBytes)) free")
                                    .font(AppFont.metric(22))
                                    .foregroundStyle(.white)
                                Text("of \(MetricFormat.disk(totalBytes))")
                                    .font(AppFont.micro)
                                    .foregroundStyle(Color.white.opacity(0.50))
                            }
                        } else {
                            Text(store.isScanning ? "Scanning disk…" : "Tap Scan")
                                .font(AppFont.panelTitle)
                                .foregroundStyle(.white)
                        }
                    }

                    Spacer(minLength: 4)

                    Button {
                        store.startScan()
                    } label: {
                        if store.isScanning {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 24, height: 22)
                        } else {
                            Label(snap == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.isScanning || store.isCleaning)
                }

                // Visual storage bar (kept used + reclaimable highlight + free)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.08))

                        if total > 0 {
                            HStack(spacing: 1) {
                                Rectangle()
                                    .fill(AppGradients.accentHorizontal)
                                    .frame(width: max(0, geo.size.width * keepFraction))

                                if cleanableFraction > 0.003 {
                                    Rectangle()
                                        .fill(AppColors.success)
                                        .frame(width: max(4, geo.size.width * cleanableFraction))
                                }
                            }
                            .clipShape(Capsule())
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: usedFraction)
                        }
                    }
                }
                .frame(height: 6)

                HStack(spacing: 8) {
                    if reclaimable > 0 {
                        Text("\(MetricFormat.disk(reclaimable)) safe to clean")
                            .foregroundStyle(AppColors.success)
                    } else if snap != nil {
                        Text("Caches look clean")
                            .foregroundStyle(AppColors.success)
                    }

                    Spacer(minLength: 4)

                    if let purgeable = snap?.purgeableBytes, purgeable > 100_000_000 {
                        Text("macOS purgeable \(MetricFormat.disk(purgeable))")
                            .foregroundStyle(Color.white.opacity(0.48))
                    } else if let count = snap?.localSnapshotCount, count > 0 {
                        Text("\(count) APFS snapshot\(count == 1 ? "" : "s")")
                            .foregroundStyle(Color.white.opacity(0.48))
                    } else if free > 0 {
                        Text("\(Int((usedFraction * 100).rounded()))% used")
                            .foregroundStyle(Color.white.opacity(0.48))
                    }
                }
                .font(.system(size: 9.5, weight: .medium))
            }
        }
    }

    // MARK: - Safe Cleanup Categories

    private var safeCleanupSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SAFE TO CLEAN")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.white.opacity(0.55))
                Spacer()
                Text("Never touches Documents or macOS")
                    .font(AppFont.micro)
                    .foregroundStyle(Color.white.opacity(0.40))
            }
            .padding(.horizontal, 4)

            if let snap = store.snapshot {
                VStack(spacing: 6) {
                    ForEach(snap.categories) { category in
                        categoryRow(category)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning user caches, developer caches, logs & Trash…")
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { ObsidianCardBackground(cornerRadius: 13) }
            }
        }
    }

    private func categoryRow(_ category: CleanableCategory) -> some View {
        let isSelected = store.selectedKinds.contains(category.kind) && !category.isEmpty

        return HStack(spacing: 8) {
            Button {
                store.toggle(category.kind)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(
                            category.isEmpty
                                ? Color.white.opacity(0.18)
                                : (isSelected ? AppColors.accentGlow : Color.white.opacity(0.38))
                        )

                    Image(systemName: category.kind.symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(isSelected ? AppColors.accentGlow : Color.white.opacity(0.65))
                        .frame(width: 22, height: 22)
                        .background {
                            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                .fill(AppColors.accent.opacity(isSelected ? 0.16 : 0.08))
                        }

                    VStack(alignment: .leading, spacing: 1.5) {
                        Text(category.kind.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(category.isEmpty ? Color.white.opacity(0.45) : .white)
                            .lineLimit(1)

                        Text(category.kind.safetyNote)
                            .font(AppFont.micro)
                            .foregroundStyle(Color.white.opacity(0.48))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Text(category.isEmpty ? "Empty" : MetricFormat.disk(category.bytes))
                        .font(AppFont.number(11.5, weight: .semibold))
                        .foregroundStyle(category.isEmpty ? Color.white.opacity(0.35) : (isSelected ? AppColors.accentGlow : .white))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(category.isEmpty || store.isCleaning)

            Button {
                store.revealInFinder(category.primaryURL)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(category.kind.title) in Finder")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background {
            ObsidianCardBackground(cornerRadius: 12, isHighlighted: isSelected)
        }
    }

    // MARK: - Read-only System Data & Downloads Explorer

    private func insightSection(
        title: String,
        subtitle: String,
        icon: String,
        items: [StorageInsightItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
                Spacer()
                Text(subtitle)
                    .font(AppFont.micro)
                    .foregroundStyle(Color.white.opacity(0.42))
            }
            .padding(.horizontal, 4)

            VStack(spacing: 4) {
                ForEach(items) { item in
                    HStack(spacing: 7) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Text(item.locationLabel)
                                .font(AppFont.micro)
                                .foregroundStyle(Color.white.opacity(0.45))
                        }

                        Spacer(minLength: 6)

                        Text(MetricFormat.disk(item.bytes))
                            .font(AppFont.number(11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.85))

                        Button {
                            store.revealInFinder(item.url)
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: 11))
                                .foregroundStyle(AppColors.accentGlow.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        .help("Reveal \(item.name) in Finder")
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background {
                        ObsidianCardBackground(cornerRadius: 10)
                    }
                }
            }
        }
    }

    // MARK: - Action Footer & Feedback

    private var cleanFooterBar: some View {
        HStack(spacing: 8) {
            if store.isCleaning {
                ProgressView().controlSize(.small)
                Text("Cleaning selected caches…")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Selected to free")
                        .font(AppFont.micro)
                        .foregroundStyle(Color.white.opacity(0.50))
                    Text(store.selectedBytes > 0 ? MetricFormat.disk(store.selectedBytes) : "Nothing selected")
                        .font(AppFont.number(13, weight: .semibold))
                        .foregroundStyle(store.selectedBytes > 0 ? AppColors.accentGlow : .secondary)
                }

                Spacer()

                Button {
                    store.requestClean()
                } label: {
                    Label("Clean Selected", systemImage: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(store.canClean ? Color.black : Color.white.opacity(0.35))
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(store.canClean ? Color.white : Color.white.opacity(0.10))
                        }
                }
                .buttonStyle(.plain)
                .disabled(!store.canClean)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            ObsidianCardBackground(cornerRadius: 12, isHighlighted: store.canClean)
        }
    }

    private func cleanResultBanner(_ result: CleanResult) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColors.success)

            Text(
                "Freed \(MetricFormat.disk(result.freedBytes)) (\(result.removedItems) removed"
                    + (result.skippedItems > 0 ? ", \(result.skippedItems) in-use skipped)" : ")")
            )
            .font(AppFont.micro)
            .foregroundStyle(.white)
            .lineLimit(2)

            Spacer(minLength: 4)

            Button {
                store.dismissCleanResult()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppColors.success.opacity(0.14))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AppColors.success.opacity(0.35), lineWidth: 1)
        }
    }
}

// MARK: - Confirmation Sheet

private struct CleanConfirmationSheet: View {
    let categories: [CleanableCategory]
    let totalBytes: UInt64
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColors.accentGlow)
                    .frame(width: 32, height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(AppColors.accent.opacity(0.18))
                    }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Clean Selected Storage?")
                        .font(AppFont.panelTitle)
                        .foregroundStyle(.white)
                    Text("Up to \(MetricFormat.disk(totalBytes)) will be freed immediately")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColors.accentGlow)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(categories) { category in
                    HStack {
                        Text(category.kind.title)
                            .font(AppFont.caption)
                            .foregroundStyle(.white)
                        Spacer()
                        Text(MetricFormat.disk(category.bytes))
                            .font(AppFont.number(11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.75))
                    }
                }
            }
            .padding(10)
            .background { ObsidianCardBackground(cornerRadius: 10) }

            Text("Only user-owned regenerable caches, logs, and selected Trash items are removed. Documents, Applications, Preferences, Keychains, and macOS system files are never touched.")
                .font(AppFont.micro)
                .foregroundStyle(Color.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(action: onConfirm) {
                    Text("Clean \(MetricFormat.disk(totalBytes))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white)
                        }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 340)
        .preferredColorScheme(.dark)
    }
}
