//
//  MacDoctor/Views/Settings/SettingsView.swift
//  Mac Doctor
//
//  Settings tab: menu bar readout & icon, temperature unit, refresh interval,
//  Low Impact Mode (battery-aware polling), Launch at Login (SMAppService),
//  and alert thresholds with optional macOS notifications (UserNotifications).
//

import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    let vitals: VitalsStore

    @State private var copiedReport = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                menuBarCard
                pollingAndPowerCard
                alertsCard
                footerCard
            }
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            await settings.refreshSystemStatuses()
        }
    }

    // MARK: - Menu Bar & Units (GlassSurface)

    private var menuBarCard: some View {
        GlassSurface(cornerRadius: 18, contentPadding: 13) {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle(icon: "menubar.rectangle", title: "Menu Bar & Display")

                VStack(alignment: .leading, spacing: 5) {
                    Text("Live Readout")
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)

                    segmentedPills(
                        items: MenuBarReadout.allCases,
                        selection: settings.menuBarReadout,
                        label: \.label
                    ) { choice in
                        settings.menuBarReadout = choice
                    }
                }

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Icon")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)

                        segmentedPills(
                            items: MenuBarIconChoice.allCases,
                            selection: settings.menuBarIcon,
                            label: \.label
                        ) { choice in
                            settings.menuBarIcon = choice
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Temp Unit")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)

                        segmentedPills(
                            items: TemperatureUnit.allCases,
                            selection: settings.temperatureUnit,
                            label: \.symbol
                        ) { unit in
                            settings.temperatureUnit = unit
                        }
                    }
                    .frame(width: 96)
                }
            }
        }
    }

    // MARK: - Polling & Power

    private var pollingAndPowerCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle(icon: "bolt.batteryblock", title: "Polling & Startup")

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Refresh Interval")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text("Active: \(vitals.activePollingSeconds)s")
                            .font(AppFont.number(9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    segmentedPills(
                        items: RefreshIntervalOption.allCases,
                        selection: settings.refreshInterval,
                        label: \.label
                    ) { option in
                        settings.refreshInterval = option
                    }
                }

                Divider().opacity(0.4)

                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $settings.lowImpactModeEnabled) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Low Impact Mode")
                                .font(.system(size: 12, weight: .medium))
                            Text("Slows polling automatically while on battery")
                                .font(AppFont.micro)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    if vitals.isLowImpactActive {
                        Label(
                            "Active on battery · polling every \(vitals.activePollingSeconds)s",
                            systemImage: "leaf.fill"
                        )
                        .font(AppFont.micro)
                        .foregroundStyle(AppColors.success)
                    }
                }

                Divider().opacity(0.4)

                VStack(alignment: .leading, spacing: 5) {
                    Toggle(isOn: Binding(
                        get: { settings.loginItemStatus.isEnabled },
                        set: { settings.setLaunchAtLogin($0) }
                    )) {
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Launch at Login")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Uses macOS Login Items (SMAppService)")
                                    .font(AppFont.micro)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    if case .requiresApproval = settings.loginItemStatus {
                        HStack(spacing: 6) {
                            Label("Approval needed in System Settings", systemImage: "exclamationmark.circle")
                                .font(AppFont.micro)
                                .foregroundStyle(AppColors.warning)
                            Spacer()
                            Button("Open") {
                                settings.openLoginItemsSettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    } else if case .unavailable(let note) = settings.loginItemStatus {
                        Text(note)
                            .font(AppFont.micro)
                            .foregroundStyle(.secondary)
                    }

                    if let error = settings.loginItemError {
                        Text(error)
                            .font(AppFont.micro)
                            .foregroundStyle(AppColors.warning)
                    }
                }
            }
        }
    }

    // MARK: - Alerts & Notifications

    private var alertsCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle(icon: "bell.badge", title: "Alerts & Thresholds")

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("CPU Alert (sustained 30s)")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(settings.cpuAlertThresholdPercent.rounded()))%")
                            .font(AppFont.number(11.5, weight: .semibold))
                            .foregroundStyle(.primary)
                    }

                    Slider(value: $settings.cpuAlertThresholdPercent, in: 60...98, step: 1)
                        .controlSize(.small)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Temperature Alert")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(settings.temperatureUnit.format(settings.temperatureAlertThresholdCelsius, decimals: 0))
                            .font(AppFont.number(11.5, weight: .semibold))
                            .foregroundStyle(.primary)
                    }

                    Slider(value: $settings.temperatureAlertThresholdCelsius, in: 65...105, step: 1)
                        .controlSize(.small)
                }

                Toggle(isOn: $settings.memoryPressureAlertEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Memory Pressure Alerts")
                            .font(.system(size: 12, weight: .medium))
                        Text("Tint menu bar icon on warning or critical pressure")
                            .font(AppFont.micro)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Divider().opacity(0.4)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(
                        get: { settings.notificationsEnabled },
                        set: { enabled in
                            Task { await settings.toggleNotifications(enabled) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("macOS Notifications")
                                .font(.system(size: 12, weight: .medium))
                            Text("Optional local alerts (5-minute cooldown per alert)")
                                .font(AppFont.micro)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    HStack(spacing: 6) {
                        Text("Status: \(settings.notificationPermission.label)")
                            .font(AppFont.micro)
                            .foregroundStyle(.secondary)

                        Spacer()

                        switch settings.notificationPermission {
                        case .authorized:
                            Button("Send Test") {
                                Task { await settings.sendTestNotification() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                        case .denied:
                            Button("Open Settings") {
                                settings.openNotificationSettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                        case .notDetermined:
                            if settings.notificationsEnabled {
                                Button("Allow") {
                                    Task { await settings.requestNotificationPermission() }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }

                        case .unavailable:
                            EmptyView()
                        }
                    }

                    if let feedback = settings.testNotificationFeedback {
                        Text(feedback)
                            .font(AppFont.micro)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footerCard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    let report = vitals.diagnosticMarkdownReport()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    copiedReport = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copiedReport = false
                    }
                } label: {
                    Label(
                        copiedReport ? "Copied Snapshot!" : "Copy System Report",
                        systemImage: copiedReport ? "checkmark.circle.fill" : "doc.on.clipboard"
                    )
                    .font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("Reset Defaults") {
                    settings.resetDefaults()
                }
                .buttonStyle(.plain)
                .font(AppFont.micro)
                .foregroundStyle(.secondary)
            }

            HStack {
                Text("Mac Doctor \(appVersion)")
                    .font(AppFont.micro)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("⌘1–5 tabs · ⌘F search · ⌘, settings")
                    .font(AppFont.micro)
                    .foregroundStyle(Color.white.opacity(0.42))
            }
        }
        .padding(.horizontal, 4)
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "v\(short) (\(build))"
    }

    // MARK: - Reusable pieces

    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ObsidianCardBackground(cornerRadius: 14)
            }
    }

    private func sectionTitle(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(AppColors.accentForeground(for: colorScheme))
                .frame(width: 22, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(AppColors.accentForeground(for: colorScheme).opacity(0.11))
                }

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    private func segmentedPills<T: Identifiable & Equatable>(
        items: [T],
        selection: T,
        label: KeyPath<T, String>,
        onSelect: @escaping (T) -> Void
    ) -> some View {
        HStack(spacing: 3) {
            ForEach(items) { item in
                let isSelected = item == selection
                Button {
                    withAnimation(reduceMotion ? nil : AppMotion.snappy) {
                        onSelect(item)
                    }
                } label: {
                    Text(item[keyPath: label])
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isSelected ? AppColors.accentGlow : Color.white.opacity(0.56))
                        .frame(maxWidth: .infinity)
                        .frame(height: 23)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [AppColors.accentGlow.opacity(0.24), AppColors.accentDeep.opacity(0.20)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(AppColors.accentGlow.opacity(0.38), lineWidth: 0.75)
                                    }
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(AppColors.glassStroke.opacity(0.55), lineWidth: 1)
        }
    }
}

#if DEBUG
#Preview("Settings Light") {
    let settings = SettingsStore()
    let vitals = VitalsStore(settings: settings)
    SettingsView(settings: settings, vitals: vitals)
        .padding(16)
        .frame(width: 380, height: 440)
        .background(AppBackground())
        .preferredColorScheme(.light)
}

#Preview("Settings Dark") {
    let settings = SettingsStore()
    let vitals = VitalsStore(settings: settings)
    SettingsView(settings: settings, vitals: vitals)
        .padding(16)
        .frame(width: 380, height: 440)
        .background(AppBackground())
        .preferredColorScheme(.dark)
}
#endif
