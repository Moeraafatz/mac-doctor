//
//  MacDoctor/AppShell/AppShellView.swift
//  Mac Doctor
//
//  Root popover content styled in Black Liquid Glass with Claude-orange
//  accents: clean minimal header (with Settings button ⌘,), five-tab glass
//  capsule bar (Overview, Temps, Procs, Network, Clean), keyboard shortcuts
//  (⌘1–⌘5, ⌘,, ⌘F, ⌘R), active tab, and quiet footer.
//

import AppKit
import SwiftUI

struct AppShellView: View {
    @State private var selection: AppTab = .overview
    @State private var focusSearchToken = 0
    let vitals: VitalsStore
    let settings: SettingsStore
    @State private var processes: ProcessStore
    @State private var network: NetworkStore
    @State private var storage: StorageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @MainActor
    init(
        vitals: VitalsStore? = nil,
        settings: SettingsStore? = nil,
        processes: ProcessStore = ProcessStore(),
        network: NetworkStore = NetworkStore(),
        storage: StorageStore = StorageStore()
    ) {
        let resolvedSettings = settings ?? SettingsStore()
        self.settings = resolvedSettings
        self.vitals = vitals ?? VitalsStore(settings: resolvedSettings)
        _processes = State(initialValue: processes)
        _network = State(initialValue: network)
        _storage = State(initialValue: storage)
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(selection: $selection, health: vitals.health)
                .padding(.horizontal, AppLayout.horizontalInset)
                .padding(.top, 13)
                .padding(.bottom, 10)

            AppTabBar(selection: $selection)
                .padding(.horizontal, AppLayout.horizontalInset)
                .padding(.bottom, 12)

            ZStack {
                content
                    .id(selection)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, AppLayout.horizontalInset)
            .padding(.bottom, 11)

            FooterView()
        }
        .background { keyboardShortcuts }
        .frame(width: AppLayout.popoverWidth, height: AppLayout.popoverHeight)
        .background(AppBackground())
        .tint(AppColors.accent)
        .preferredColorScheme(.dark)
        .onAppear {
            vitals.startIfNeeded()
            processes.setLowImpactActive(vitals.isLowImpactActive)
        }
        .task {
            processes.setProcessesTabVisible(selection == .processes)
            await processes.run()
        }
        .task {
            network.setNetworkTabVisible(selection == .network)
            await network.runConnectionPolling()
        }
        .onChange(of: selection) { _, next in
            processes.setProcessesTabVisible(next == .processes)
            network.setNetworkTabVisible(next == .network)
        }
        .onChange(of: vitals.isLowImpactActive) { _, active in
            processes.setLowImpactActive(active)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .overview:
            OverviewView(
                snapshot: vitals.snapshot,
                history: vitals.cpuHistory,
                onInspectPID: { pid in
                    processes.searchText = String(pid)
                    selectTab(.processes)
                },
                onOpenCleaner: {
                    selectTab(.cleaner)
                }
            )
        case .temperatures:
            TemperaturesView(
                sample: vitals.snapshot.temperatures,
                thermal: vitals.snapshot.thermal,
                history: vitals.temperatureHistory
            )
        case .processes:
            ProcessesView(
                store: processes,
                sleepBlockers: vitals.snapshot.sleepBlockers,
                focusSearchToken: focusSearchToken
            )
        case .network:
            NetworkView(
                store: network,
                liveSample: vitals.snapshot.network,
                throughputHistory: vitals.networkHistory,
                todayDownloadedBytes: vitals.todayDownloadedBytes,
                todayUploadedBytes: vitals.todayUploadedBytes
            )
        case .cleaner:
            CleanerView(
                store: storage,
                onDiskChanged: {
                    Task { await vitals.refreshOnce() }
                }
            )
        case .settings:
            SettingsView(settings: settings, vitals: vitals)
        }
    }

    /// Invisible keyboard-shortcut layer: ⌘1–⌘5 switch tabs, ⌘, opens Settings,
    /// ⌘F focuses Process search, ⌘R refreshes.
    private var keyboardShortcuts: some View {
        Group {
            Button("") { selectTab(.overview) }.keyboardShortcut("1", modifiers: .command)
            Button("") { selectTab(.temperatures) }.keyboardShortcut("2", modifiers: .command)
            Button("") { selectTab(.processes) }.keyboardShortcut("3", modifiers: .command)
            Button("") { selectTab(.network) }.keyboardShortcut("4", modifiers: .command)
            Button("") { selectTab(.cleaner) }.keyboardShortcut("5", modifiers: .command)
            Button("") { selectTab(selection == .settings ? .overview : .settings) }.keyboardShortcut(",", modifiers: .command)
            Button("") {
                selectTab(.processes)
                focusSearchToken &+= 1
            }.keyboardShortcut("f", modifiers: .command)
            Button("") {
                Task {
                    await vitals.refreshOnce()
                    await processes.refreshOnce()
                    await network.refreshConnectionInfo()
                    if selection == .cleaner {
                        storage.startScan()
                    }
                }
            }.keyboardShortcut("r", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func selectTab(_ tab: AppTab) {
        withAnimation(reduceMotion ? nil : AppMotion.snappy) {
            selection = tab
        }
    }
}

// MARK: - Header

private struct HeaderView: View {
    @Binding var selection: AppTab
    let health: SystemHealth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var healthTone: StatusTone {
        switch health {
        case .stable: .success
        case .elevated: .warning
        case .critical: .critical
        case .starting: .neutral
        }
    }

    var body: some View {
        let isSettingsOpen = selection == .settings

        HStack(spacing: 10) {
            AppMark()

            Text("Mac Doctor")
                .font(AppFont.screenTitle)
                .foregroundStyle(.white)

            Spacer(minLength: 8)

            StatusBadge(label: health.label, tone: healthTone)

            Button {
                withAnimation(reduceMotion ? nil : AppMotion.snappy) {
                    selection = isSettingsOpen ? .overview : .settings
                }
            } label: {
                Image(systemName: isSettingsOpen ? "gearshape.fill" : "gearshape")
                    .foregroundStyle(isSettingsOpen ? AppColors.accentGlow : Color.white.opacity(0.76))
            }
            .buttonStyle(QuietIconButtonStyle(reduceMotion: reduceMotion))
            .overlay {
                if isSettingsOpen {
                    Circle()
                        .strokeBorder(AppColors.accentGlow.opacity(0.55), lineWidth: 1)
                }
            }
            .help(isSettingsOpen ? "Back to Overview (⌘,)" : "Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
    }
}

private struct AppMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppGradients.accent)
                .frame(width: 32, height: 32)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.55), radius: 8, x: 0, y: 3)

            Image(systemName: "stethoscope")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Footer

private struct FooterView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.shield")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(AppColors.accentGlow.opacity(0.85))

            Text("Local only · No telemetry")
                .font(AppFont.micro)
                .foregroundStyle(Color.white.opacity(0.55))
                .lineLimit(1)

            Spacer(minLength: 8)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(FooterButtonStyle(reduceMotion: reduceMotion))
            .help("Quit Mac Doctor")
            .accessibilityLabel("Quit Mac Doctor")
        }
        .padding(.horizontal, AppLayout.horizontalInset)
        .frame(height: 32)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppColors.hairline)
                .frame(height: 0.5)
        }
    }
}

#Preview("Black Liquid Glass") {
    AppShellView()
}
