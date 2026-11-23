//
//  MacDoctor/Views/Cleaner/AppRemoverView.swift
//  Mac Doctor
//
//  Deep App Remover inside the Clean tab. Lists only user-installed apps from
//  the internet or Mac App Store, scans their exact ~/Library leftovers, and
//  moves checked items to Trash behind an interactive review sheet.
//

import AppKit
import SwiftUI

struct AppRemoverView: View {
    @Bindable var store: AppRemoverStore
    var onDiskChanged: (() -> Void)? = nil

    @State private var hoveredTrashID: String?

    var body: some View {
        VStack(spacing: 8) {
            summaryCard

            searchAndSortBar

            if let result = store.lastResult {
                removalResultBanner(result)
            }

            if store.isRemoving {
                removingBanner
            }

            ScrollView(.vertical, showsIndicators: false) {
                appListContent
                    .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            store.loadIfNeeded()
        }
        .sheet(item: $store.pendingPlan) { plan in
            AppRemovalSheet(
                plan: plan,
                appIcon: store.icon(for: plan.app),
                selectedItemIDs: store.selectedItemIDs,
                selectedCount: store.selectedPlanItems.count,
                selectedBytes: store.selectedPlanBytes,
                onToggle: { store.toggleItem($0) },
                onReveal: { store.revealInFinder($0) },
                onCancel: { store.cancelRemoval() },
                onConfirm: { store.confirmRemoval(onFinished: onDiskChanged) }
            )
        }
    }

    // MARK: - Summary Header Card

    private var summaryCard: some View {
        GlassSurface(cornerRadius: 16, contentPadding: 11) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("INSTALLED APPS")
                        .font(AppFont.micro)
                        .tracking(0.9)
                        .foregroundStyle(Color.white.opacity(0.65))

                    if store.hasLoaded {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text("\(store.apps.count) apps")
                                .font(AppFont.metric(19))
                                .foregroundStyle(.white)
                            Text("· \(MetricFormat.disk(store.totalInstalledBytes))")
                                .font(AppFont.number(11.5, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.55))
                        }
                    } else {
                        Text("Scanning Applications…")
                            .font(AppFont.panelTitle)
                            .foregroundStyle(.white)
                    }

                    Text("Built-in macOS apps are hidden & protected")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.45))
                }

                Spacer(minLength: 4)

                Button {
                    store.reload()
                } label: {
                    if store.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 24, height: 22)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.isLoading || store.isRemoving)
            }
        }
    }

    // MARK: - Search & Sort Bar

    private var searchAndSortBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))

                TextField("Search apps…", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .font(AppFont.caption)
                    .foregroundStyle(.white)

                if !store.searchText.isEmpty {
                    Button {
                        store.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background { ObsidianCardBackground(cornerRadius: 8) }

            HStack(spacing: 2) {
                ForEach(AppSortOrder.allCases) { order in
                    let isSelected = store.sortOrder == order
                    Button {
                        store.sortOrder = order
                    } label: {
                        Text(order.label)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.65))
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .background {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background { ObsidianCardBackground(cornerRadius: 8) }
        }
    }

    // MARK: - App List

    @ViewBuilder
    private var appListContent: some View {
        let items = store.filteredApps
        if store.isLoading && !store.hasLoaded {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Scanning /Applications and ~/Applications…")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { ObsidianCardBackground(cornerRadius: 12) }
        } else if items.isEmpty {
            VStack(spacing: 4) {
                Text(store.searchText.isEmpty ? "No removable third-party apps found" : "No apps match \"\(store.searchText)\"")
                    .font(AppFont.caption)
                    .foregroundStyle(.white)
                Text("Only downloaded and App Store apps in Applications are listed.")
                    .font(AppFont.micro)
                    .foregroundStyle(Color.white.opacity(0.48))
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background { ObsidianCardBackground(cornerRadius: 12) }
        } else {
            LazyVStack(spacing: 5) {
                ForEach(items) { app in
                    appRow(app)
                }
            }
        }
    }

    private func appRow(_ app: InstalledApp) -> some View {
        let isPreparing = store.preparingAppID == app.id
        let isTrashHovered = hoveredTrashID == app.id

        return HStack(spacing: 8) {
            Image(nsImage: store.icon(for: app))
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 1.5) {
                Text(app.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 5) {
                    Text(app.source.rawValue)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.70))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background {
                            Capsule().fill(Color.white.opacity(0.09))
                        }

                    if let version = app.version, !version.isEmpty {
                        Text("v\(version)")
                            .font(AppFont.micro)
                            .foregroundStyle(Color.white.opacity(0.42))
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 4)

            Text(MetricFormat.disk(app.appSizeBytes))
                .font(AppFont.number(11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))

            Button {
                store.revealInFinder(app.url)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Reveal \(app.name) in Finder")
            .accessibilityLabel("Reveal \(app.name) in Finder")

            Button {
                store.prepareRemoval(for: app)
            } label: {
                Group {
                    if isPreparing {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "trash")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(isTrashHovered ? AppColors.critical : Color.white.opacity(0.68))
                    }
                }
                .frame(width: 24, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isTrashHovered ? AppColors.critical.opacity(0.16) : Color.white.opacity(0.06))
                }
            }
            .buttonStyle(.plain)
            .disabled(store.isRemoving || store.preparingAppID != nil)
            .onHover { hovering in
                hoveredTrashID = hovering ? app.id : (hoveredTrashID == app.id ? nil : hoveredTrashID)
            }
            .help("Review & Remove \(app.name) and its leftovers")
            .accessibilityLabel("Remove \(app.name)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background { ObsidianCardBackground(cornerRadius: 11) }
    }

    // MARK: - Banners

    private var removingBanner: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Moving app and leftovers to Trash…")
                .font(AppFont.caption)
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background { ObsidianCardBackground(cornerRadius: 10, isHighlighted: true) }
    }

    private func removalResultBanner(_ result: AppRemovalResult) -> some View {
        let isCleanSuccess = !result.appBundleNeedsFinder && result.failedItems.isEmpty
        let toneColor = isCleanSuccess ? AppColors.success : AppColors.warning

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: isCleanSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(toneColor)

                Text(resultMessage(for: result))
                    .font(AppFont.micro)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                Button {
                    store.dismissResult()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if result.appBundleNeedsFinder {
                HStack {
                    Button {
                        store.revealInFinder(result.appBundleURL)
                    } label: {
                        Label("Reveal \(result.appBundleURL.lastPathComponent) in Finder", systemImage: "folder")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 9)
                            .frame(height: 22)
                            .background {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.white)
                            }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(toneColor.opacity(0.14))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(toneColor.opacity(0.35), lineWidth: 1)
        }
    }

    private func resultMessage(for result: AppRemovalResult) -> String {
        if result.appBundleNeedsFinder {
            if result.trashedCount > 0 {
                return "Moved \(result.trashedCount) leftover(s) (\(MetricFormat.disk(result.freedBytes))) to Trash. macOS requires Finder to move \(result.appName).app."
            }
            return "macOS requires Finder to move \(result.appName).app (owned by system installer)."
        }
        if !result.failedItems.isEmpty {
            return "Moved \(result.trashedCount) item(s) for \(result.appName) (\(MetricFormat.disk(result.freedBytes))) to Trash; \(result.failedItems.count) could not be moved."
        }
        return "Moved \(result.appName) (\(result.trashedCount) item\(result.trashedCount == 1 ? "" : "s"), \(MetricFormat.disk(result.freedBytes))) to Trash."
    }
}

// MARK: - Review & Confirmation Sheet

private struct AppRemovalSheet: View {
    let plan: AppRemovalPlan
    let appIcon: NSImage
    let selectedItemIDs: Set<String>
    let selectedCount: Int
    let selectedBytes: UInt64
    let onToggle: (String) -> Void
    let onReveal: (URL) -> Void
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Remove \(plan.app.name)?")
                        .font(AppFont.panelTitle)
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(subtitleLine)
                        .font(AppFont.micro)
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()
            }

            if plan.isRunning {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColors.warning)
                    Text("\(plan.app.name) is running — it will be quit before removing.")
                        .font(AppFont.micro)
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppColors.warning.opacity(0.14))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(AppColors.warning.opacity(0.35), lineWidth: 1)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("ITEMS TO MOVE TO TRASH (\(plan.items.count))")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(Color.white.opacity(0.55))
                    Spacer()
                    Text(MetricFormat.disk(selectedBytes))
                        .font(AppFont.number(10.5, weight: .semibold))
                        .foregroundStyle(.white)
                }

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 5) {
                        ForEach(plan.items) { item in
                            itemRow(item)
                        }
                    }
                }
                .frame(maxHeight: 210)
            }
            .padding(10)
            .background { ObsidianCardBackground(cornerRadius: 10) }

            Text("Selected files are moved to Trash (reversible). Built-in macOS apps and system files are never touched.")
                .font(AppFont.micro)
                .foregroundStyle(Color.white.opacity(0.60))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer()

                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button(action: onConfirm) {
                    Text(confirmLabel)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(selectedCount > 0 ? Color.white : Color.white.opacity(0.40))
                        .padding(.horizontal, 12)
                        .frame(height: 27)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selectedCount > 0 ? AppColors.critical : Color.white.opacity(0.10))
                        }
                }
                .buttonStyle(.plain)
                .disabled(selectedCount == 0)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 365)
        .preferredColorScheme(.dark)
    }

    private var subtitleLine: String {
        let leftoverCount = max(0, plan.items.count - 1)
        let leftoverLabel = leftoverCount == 0
            ? "No ~/Library leftovers found"
            : "\(leftoverCount) ~/Library leftover\(leftoverCount == 1 ? "" : "s") found"
        if let bid = plan.app.bundleIdentifier, !bid.isEmpty {
            return "\(bid) · \(leftoverLabel)"
        }
        return leftoverLabel
    }

    private var confirmLabel: String {
        if selectedCount == 0 {
            return "Select items to remove"
        }
        return "Move \(selectedCount) Item\(selectedCount == 1 ? "" : "s") (\(MetricFormat.disk(selectedBytes))) to Trash"
    }

    private func itemRow(_ item: AppRemovalItem) -> some View {
        let isSelected = selectedItemIDs.contains(item.id)

        return HStack(spacing: 7) {
            Button {
                onToggle(item.id)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.32))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isSelected ? .white : Color.white.opacity(0.45))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(item.kind.rawValue)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.42))
                    }

                    Spacer(minLength: 4)

                    Text(MetricFormat.disk(item.bytes))
                        .font(AppFont.number(10.5, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.white.opacity(0.38))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                onReveal(item.url)
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .help("Reveal \(item.displayName) in Finder")
        }
        .padding(.vertical, 3)
    }
}
