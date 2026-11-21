//
//  MacDoctor/Views/Processes/ProcessesView.swift
//  Mac Doctor
//
//  Processes (Task Manager) tab. Live 2-second process list sortable by CPU %,
//  Memory, Energy Impact, and per-process Network, with optional App + Helper
//  grouping, sleep-blocker indicators, search (⌘F), Top Offenders banner, and
//  policy-enforced Quit / Force Quit / Finder Relaunch confirmation sheets.
//

import AppKit
import SwiftUI

struct ProcessesView: View {
    @Bindable var store: ProcessStore
    var sleepBlockers: [SleepBlocker] = []
    var focusSearchToken: Int = 0

    @FocusState private var isSearchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sleepBlockerByPID: [pid_t: SleepBlocker] {
        Dictionary(uniqueKeysWithValues: sleepBlockers.map { ($0.pid, $0) })
    }

    var body: some View {
        let groups = store.groupedProcesses
        let blockers = sleepBlockerByPID

        VStack(spacing: 8) {
            if !store.snapshot.offenders.isEmpty {
                TopOffendersBanner(
                    offenders: store.snapshot.offenders,
                    onSelect: { pid in
                        withAnimation(reduceMotion ? nil : AppMotion.gentle) {
                            store.searchText = String(pid)
                        }
                    }
                )
            }

            if let feedback = store.lastFeedback {
                feedbackBanner(feedback)
            }

            controlsBar(
                visibleCount: groups.count,
                totalCount: store.snapshot.processes.count
            )

            if !store.snapshot.nettopAvailable || store.snapshot.anyEstimatedEnergy {
                statusStrip
            }

            if groups.isEmpty {
                emptyListView
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(groups) { group in
                            if group.isMultiProcess {
                                groupSection(group, blockers: blockers)
                            } else {
                                let entry = group.primaryEntry
                                ProcessRowView(
                                    entry: entry,
                                    icon: store.icon(for: entry),
                                    sortKey: store.sortKey,
                                    quitAttempted: store.hasAttemptedQuit(entry),
                                    nettopAvailable: store.snapshot.nettopAvailable,
                                    sleepBlockerReason: blockers[entry.pid]?.reason,
                                    onPrimaryAction: {
                                        store.requestPrimaryAction(for: entry)
                                    }
                                )
                                .contextMenu {
                                    rowContextMenu(for: entry)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: focusSearchToken) { _, _ in
            isSearchFocused = true
        }
        .sheet(item: $store.pendingAction) { action in
            ProcessConfirmationSheet(
                action: action,
                icon: store.icon(for: action.entry),
                onCancel: { store.cancelPendingAction() },
                onConfirm: {
                    Task {
                        await store.confirmPendingAction()
                    }
                }
            )
        }
    }

    // MARK: - Grouped App + Helper section

    @ViewBuilder
    private func groupSection(_ group: ProcessGroup, blockers: [pid_t: SleepBlocker]) -> some View {
        let isExpanded = store.expandedGroupIDs.contains(group.id)
        let groupSleepReason = group.members.compactMap { blockers[$0.pid]?.reason }.first

        VStack(spacing: 4) {
            ProcessGroupHeaderRow(
                group: group,
                icon: store.icon(for: group.primaryEntry),
                sortKey: store.sortKey,
                isExpanded: isExpanded,
                quitAttempted: store.hasAttemptedQuit(group.primaryEntry),
                nettopAvailable: store.snapshot.nettopAvailable,
                sleepBlockerReason: groupSleepReason,
                onToggleExpand: {
                    withAnimation(reduceMotion ? nil : AppMotion.snappy) {
                        store.toggleGroupExpanded(group.id)
                    }
                },
                onPrimaryAction: {
                    store.requestPrimaryAction(for: group.primaryEntry)
                }
            )
            .contextMenu {
                rowContextMenu(for: group.primaryEntry)
            }

            if isExpanded {
                VStack(spacing: 4) {
                    ForEach(group.members) { member in
                        ProcessRowView(
                            entry: member,
                            icon: store.icon(for: member),
                            sortKey: store.sortKey,
                            quitAttempted: store.hasAttemptedQuit(member),
                            nettopAvailable: store.snapshot.nettopAvailable,
                            sleepBlockerReason: blockers[member.pid]?.reason,
                            isChildRow: true,
                            onPrimaryAction: {
                                store.requestPrimaryAction(for: member)
                            }
                        )
                        .contextMenu {
                            rowContextMenu(for: member)
                        }
                    }
                }
                .padding(.leading, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Search, Group Toggle & Sort controls

    private func controlsBar(visibleCount: Int, totalCount: Int) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.50))

                    TextField("Search name or PID (⌘F)", text: $store.searchText)
                        .textFieldStyle(.plain)
                        .font(AppFont.body)
                        .focused($isSearchFocused)

                    if !store.searchText.isEmpty {
                        Button {
                            store.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }

                    Text(store.groupByApp ? "\(visibleCount)" : "\(visibleCount)/\(totalCount)")
                        .font(AppFont.number(9.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            Capsule().fill(Color.white.opacity(0.06))
                        }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background {
                    ObsidianCardBackground(cornerRadius: 10)
                }

                Button {
                    withAnimation(reduceMotion ? nil : AppMotion.snappy) {
                        store.groupByApp.toggle()
                    }
                } label: {
                    Image(systemName: store.groupByApp ? "square.stack.3d.up.fill" : "list.bullet")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(store.groupByApp ? AppColors.accentGlow : Color.white.opacity(0.60))
                        .frame(width: 30, height: 30)
                        .background {
                            ObsidianCardBackground(cornerRadius: 10, isHighlighted: store.groupByApp)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(store.groupByApp ? "Grouped by app (click for flat list)" : "Flat process list (click to group by app)")
                .accessibilityLabel(store.groupByApp ? "Grouped by app" : "Flat list")
            }

            HStack(spacing: 4) {
                ForEach(ProcessSortKey.allCases) { key in
                    let isSelected = store.sortKey == key
                    Button {
                        withAnimation(reduceMotion ? nil : AppMotion.snappy) {
                            store.sortKey = key
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: key.symbol)
                                .font(.system(size: 9.5, weight: .semibold))
                            Text(key.title)
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(isSelected ? AppColors.accentGlow : Color.white.opacity(0.56))
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [AppColors.accentGlow.opacity(0.24), AppColors.accentDeep.opacity(0.20)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(AppColors.accentGlow.opacity(0.38), lineWidth: 0.75)
                                    }
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(3)
            .background {
                ObsidianCardBackground(cornerRadius: 10)
            }
        }
    }

    // MARK: - Status & Feedback strips

    private var statusStrip: some View {
        HStack(spacing: 8) {
            if !store.snapshot.nettopAvailable {
                Label("Per-process network unavailable", systemImage: "wifi.exclamationmark")
                    .font(AppFont.micro)
                    .foregroundStyle(AppColors.warning)
                    .lineLimit(1)
            } else if store.snapshot.anyEstimatedEnergy {
                Label("Energy marked \"est.\" is estimated", systemImage: "info.circle")
                    .font(AppFont.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private func feedbackBanner(_ feedback: ProcessActionResult) -> some View {
        let color = feedback.isError ? AppColors.critical : AppColors.success
        return HStack(spacing: 7) {
            Image(systemName: feedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)

            Text(feedback.message)
                .font(AppFont.micro)
                .foregroundStyle(.primary)
                .lineLimit(2)

            Spacer(minLength: 4)

            Button {
                store.dismissFeedback()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss message")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(0.12))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(color.opacity(0.30), lineWidth: 1)
        }
    }

    private var emptyListView: some View {
        VStack(spacing: 6) {
            Image(systemName: store.snapshot.processes.isEmpty ? "list.bullet.rectangle" : "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)

            Text(store.snapshot.processes.isEmpty ? "Reading processes…" : "No matching processes")
                .font(AppFont.panelTitle)
                .foregroundStyle(.primary)

            if !store.searchText.isEmpty {
                Button("Clear search") {
                    store.searchText = ""
                }
                .buttonStyle(.link)
                .font(AppFont.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    // MARK: - Context menu

    @ViewBuilder
    private func rowContextMenu(for entry: ProcessEntry) -> some View {
        switch entry.policy {
        case .allowed:
            Button("Quit \(entry.name)…") {
                store.requestQuit(for: entry)
            }
            if store.hasAttemptedQuit(entry) {
                Button("Force Quit \(entry.name)…", role: .destructive) {
                    store.requestForceQuit(for: entry)
                }
            }
            Divider()
        case .relaunchOnly:
            Button("Relaunch Finder…") {
                store.requestPrimaryAction(for: entry)
            }
            Divider()
        case .blocked(let reason):
            Text(reason)
            Divider()
        }

        Button("Copy PID (\(String(entry.pid)))") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(entry.pid), forType: .string)
        }
    }
}

// MARK: - Grouped App Header Row

private struct ProcessGroupHeaderRow: View {
    let group: ProcessGroup
    let icon: NSImage
    let sortKey: ProcessSortKey
    let isExpanded: Bool
    let quitAttempted: Bool
    let nettopAvailable: Bool
    let sleepBlockerReason: String?
    let onToggleExpand: () -> Void
    let onPrimaryAction: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cpuTone: StatusTone {
        if group.totalCPUPercent >= 85 { return .critical }
        if group.totalCPUPercent >= ProcessThresholds.sustainedCPUPercent { return .warning }
        return .neutral
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleExpand) {
                HStack(spacing: 8) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(group.name)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            HStack(spacing: 3) {
                                Text("\(group.members.count)")
                                    .font(AppFont.number(8.5, weight: .semibold))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 7.5, weight: .bold))
                                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            }
                            .foregroundStyle(AppColors.accentGlow)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background {
                                Capsule().fill(AppColors.accent.opacity(0.16))
                            }

                            if let sleepBlockerReason {
                                Image(systemName: "moon.zzz.fill")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(AppColors.warning)
                                    .help("Preventing sleep: \(sleepBlockerReason)")
                            }

                            if group.hasOffender {
                                Circle()
                                    .fill(AppColors.warning)
                                    .frame(width: 5, height: 5)
                            }

                            Spacer(minLength: 2)
                        }

                        HStack(spacing: 8) {
                            chip("CPU", formatCPU(group.totalCPUPercent), highlighted: sortKey == .cpu, tone: cpuTone)
                            chip("MEM", group.totalMemoryBytes > 0 ? MetricFormat.memory(group.totalMemoryBytes) : "—", highlighted: sortKey == .memory, tone: .neutral)
                            chip("ENG", group.totalEnergy.compactLabel, highlighted: sortKey == .energy, tone: group.totalEnergy.isHighEnergy ? .warning : .neutral)
                            chip("NET", formatNet(), highlighted: sortKey == .network, tone: group.totalNetworkRate >= ProcessThresholds.heavyNetworkBytesPerSecond ? .warning : .neutral)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            actionControl
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background {
            ObsidianCardBackground(cornerRadius: 12, isHighlighted: group.hasOffender || isExpanded || isHovering)
        }
        .onHover { isHovering = $0 }
        .help("\(group.name) · \(group.members.count) processes (click to \(isExpanded ? "collapse" : "expand"))")
    }

    private func chip(_ label: String, _ value: String, highlighted: Bool, tone: StatusTone) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(highlighted ? AppColors.accentGlow : Color.white.opacity(0.42))
            Text(value)
                .font(AppFont.number(9.5, weight: highlighted ? .semibold : .medium))
                .foregroundStyle(tone == .neutral ? (highlighted ? Color.white : Color.white.opacity(0.68)) : tone.color)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var actionControl: some View {
        let entry = group.primaryEntry
        switch entry.policy {
        case .allowed:
            if quitAttempted {
                Button(action: onPrimaryAction) {
                    Text("Force")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background { Capsule().fill(AppColors.critical) }
                }
                .buttonStyle(.plain)
                .help("Force Quit \(group.name)")
            } else {
                Button(action: onPrimaryAction) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isHovering ? AppColors.critical : Color.white.opacity(0.40))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
                .help("Quit \(group.name) (PID \(String(entry.pid)))")
            }

        case .relaunchOnly(let reason):
            Button(action: onPrimaryAction) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isHovering ? AppColors.accentGlow : Color.white.opacity(0.55))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(reason)

        case .blocked(let reason):
            ZStack {
                Button(action: {}) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.30))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(true)
            }
            .contentShape(Rectangle())
            .help(reason)
        }
    }

    private func formatCPU(_ percent: Double) -> String {
        if percent < 0.05 { return "0%" }
        if percent < 10 { return String(format: "%.1f%%", percent) }
        return String(format: "%.0f%%", percent)
    }

    private func formatNet() -> String {
        guard nettopAvailable else { return "—" }
        let total = group.totalNetworkRate
        if total < 1 { return "0 B/s" }
        if total < 1_000 { return "\(Int(total.rounded()))B" }
        let kb = total / 1_000
        if kb < 1_000 { return kb < 10 ? String(format: "%.1fK", kb) : "\(Int(kb.rounded()))K" }
        let mb = kb / 1_000
        if mb < 1_000 { return mb < 10 ? String(format: "%.1fM", mb) : "\(Int(mb.rounded()))M" }
        return String(format: "%.1fG", mb / 1_000)
    }
}

// MARK: - Top offenders banner

private struct TopOffendersBanner: View {
    let offenders: [ProcessOffender]
    let onSelect: (pid_t) -> Void

    var body: some View {
        GlassSurface(cornerRadius: 14, contentPadding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppColors.warning)

                    Text("TOP OFFENDERS")
                        .font(AppFont.micro)
                        .tracking(0.8)
                        .foregroundStyle(AppColors.warning)

                    Spacer(minLength: 4)

                    Text("\(offenders.count)")
                        .font(AppFont.number(9.5, weight: .semibold))
                        .foregroundStyle(AppColors.warning)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background {
                            Capsule().fill(AppColors.warning.opacity(0.15))
                        }
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(offenders.prefix(3)) { offender in
                        Button {
                            onSelect(offender.pid)
                        } label: {
                            HStack(spacing: 6) {
                                Text(offender.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Text(offender.reasons.map(\.shortLabel).joined(separator: " · "))
                                    .font(AppFont.micro)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Spacer(minLength: 0)

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if offenders.count > 3 {
                        Text("+\(offenders.count - 3) more flagged")
                            .font(AppFont.micro)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AppColors.warning.opacity(0.32), lineWidth: 1)
        }
    }
}

#if DEBUG
#Preview("Processes — Black Liquid Glass") {
    ProcessesView(store: ProcessStore(initialSnapshot: .preview))
        .padding(15)
        .frame(width: 380, height: 440)
        .background(AppBackground())
        .preferredColorScheme(.dark)
}
#endif
