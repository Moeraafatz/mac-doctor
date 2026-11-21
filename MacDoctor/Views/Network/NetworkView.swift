//
//  MacDoctor/Views/Network/NetworkView.swift
//  Mac Doctor
//
//  Network tab: live getifaddrs throughput graph, Apple networkQuality speed
//  test (with cancel + local 20-run history), validated /sbin/ping diagnostics,
//  CoreWLAN + SystemConfiguration connection info, and on-demand public IP.
//

import AppKit
import SwiftUI

struct NetworkView: View {
    @Bindable var store: NetworkStore
    let liveSample: NetworkSample?
    let throughputHistory: [ThroughputPoint]
    var todayDownloadedBytes: UInt64 = 0
    var todayUploadedBytes: UInt64 = 0

    @State private var showHistory = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let uploadColor = AppColors.accentSecondary

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                throughputPanel
                speedTestCard
                pingCard
                connectionCard
            }
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Live throughput (GlassSurface)

    private var throughputPanel: some View {
        let info = store.connectionInfo
        let downColor = AppColors.accentForeground(for: colorScheme)

        return GlassSurface(cornerRadius: 18, contentPadding: 13) {
            VStack(spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Circle().fill(downColor).frame(width: 6, height: 6)
                            Text("DOWNLOAD")
                                .font(AppFont.micro)
                                .tracking(0.7)
                                .foregroundStyle(.secondary)
                        }

                        Text(MetricFormat.rate(liveSample?.downloadBytesPerSecond))
                            .font(AppFont.number(17, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }

                    Spacer(minLength: 6)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Circle().fill(Self.uploadColor).frame(width: 6, height: 6)
                            Text("UPLOAD")
                                .font(AppFont.micro)
                                .tracking(0.7)
                                .foregroundStyle(.secondary)
                        }

                        Text(MetricFormat.rate(liveSample?.uploadBytesPerSecond))
                            .font(AppFont.number(17, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }

                    Spacer(minLength: 4)

                    StatusBadge(
                        label: info.interfaceName.map { "\(info.interfaceKind.rawValue) · \($0)" }
                            ?? info.interfaceKind.rawValue,
                        tone: info.interfaceKind == .disconnected ? .critical : .success
                    )
                }

                ThroughputGraph(points: throughputHistory)
                    .frame(height: 44)

                HStack(spacing: 6) {
                    Text("Today")
                        .foregroundStyle(Color.white.opacity(0.42))
                    Text("↓ \(MetricFormat.disk(todayDownloadedBytes))")
                        .foregroundStyle(Color.white.opacity(0.75))
                    Text("↑ \(MetricFormat.disk(todayUploadedBytes))")
                        .foregroundStyle(Color.white.opacity(0.60))
                    Spacer()
                }
                .font(AppFont.number(9.5, weight: .medium))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Live throughput: download \(MetricFormat.rate(liveSample?.downloadBytesPerSecond)), upload \(MetricFormat.rate(liveSample?.uploadBytesPerSecond))"
        )
    }

    // MARK: - Speed test card

    private var speedTestCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    cardHeader(icon: "speedometer", title: "Speed Test")

                    Spacer(minLength: 4)

                    if store.speedTestState.isRunning {
                        Button("Cancel") {
                            store.cancelSpeedTest()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Button {
                            store.startSpeedTest()
                        } label: {
                            Label("Run Test", systemImage: "play.fill")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color.white)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }

                speedTestBody

                if !store.speedTestHistory.isEmpty {
                    Divider().opacity(0.4)
                    speedTestHistorySection
                }
            }
        }
    }

    @ViewBuilder
    private var speedTestBody: some View {
        switch store.speedTestState {
        case .idle:
            if let latest = store.speedTestHistory.first {
                speedMetricsGrid(latest, caption: "Last run \(relativeDate(latest.date))")
            } else {
                Text("Uses Apple's built-in networkQuality. Only runs when you click Run Test.")
                    .font(AppFont.micro)
                    .foregroundStyle(.secondary)
            }

        case .running(let startedAt):
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Measuring throughput and responsiveness…")
                            .font(AppFont.caption)
                            .foregroundStyle(.primary)
                        Text("Elapsed \(elapsed)s · powered by /usr/bin/networkQuality")
                            .font(AppFont.micro)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

        case .completed(let result):
            speedMetricsGrid(result, caption: "Just completed")

        case .cancelled:
            Text("Speed test cancelled.")
                .font(AppFont.micro)
                .foregroundStyle(.secondary)

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(AppFont.micro)
                .foregroundStyle(AppColors.warning)
        }
    }

    private func speedMetricsGrid(_ result: SpeedTestResult, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                statBox(title: "Download", value: formatMbps(result.downloadMbps))
                statBox(title: "Upload", value: formatMbps(result.uploadMbps))
                statBox(
                    title: "RPM",
                    value: result.responsivenessRPM.map { "\($0)" } ?? "—"
                )
                statBox(
                    title: "Latency",
                    value: result.latencyMs.map { String(format: "%.0f ms", $0) } ?? "—"
                )
            }

            Text(caption)
                .font(AppFont.micro)
                .foregroundStyle(.secondary)
        }
    }

    private var speedTestHistorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    withAnimation(reduceMotion ? nil : AppMotion.snappy) {
                        showHistory.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .bold))
                            .rotationEffect(.degrees(showHistory ? 90 : 0))
                        Text("History (\(store.speedTestHistory.count)/\(SpeedTestHistoryStore.maxEntries))")
                            .font(AppFont.micro)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                if showHistory {
                    Button("Clear") {
                        store.clearSpeedTestHistory()
                    }
                    .buttonStyle(.plain)
                    .font(AppFont.micro)
                    .foregroundStyle(.secondary)
                }
            }

            if showHistory {
                VStack(spacing: 4) {
                    ForEach(store.speedTestHistory) { item in
                        HStack(spacing: 6) {
                            Text(shortTimestamp(item.date))
                                .font(AppFont.number(9, weight: .regular))
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .leading)

                            Text("↓\(formatCompactMbps(item.downloadMbps))")
                                .font(AppFont.number(9.5, weight: .semibold))
                                .foregroundStyle(.primary)

                            Text("↑\(formatCompactMbps(item.uploadMbps))")
                                .font(AppFont.number(9.5, weight: .medium))
                                .foregroundStyle(.secondary)

                            Spacer(minLength: 2)

                            if let rpm = item.responsivenessRPM {
                                Text("\(rpm) RPM")
                                    .font(AppFont.number(9, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }

                            if let ms = item.latencyMs {
                                Text(String(format: "%.0fms", ms))
                                    .font(AppFont.number(9, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.035))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Ping card

    private var pingCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    cardHeader(icon: "waveform.path.ecg", title: "Ping")

                    Spacer(minLength: 4)

                    Button {
                        store.toggleLivePing()
                    } label: {
                        Label(store.isLivePingRunning ? "Stop Live" : "Live", systemImage: store.isLivePingRunning ? "stop.fill" : "waveform")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(store.isLivePingRunning ? AppColors.accent : nil)
                    .controlSize(.small)
                    .disabled(!store.isLivePingRunning && !store.isPingHostValid)

                    if store.pingState.isRunning {
                        Button("Stop") {
                            store.cancelPing()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else if !store.isLivePingRunning {
                        Button("Ping") {
                            store.runPing()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!store.isPingHostValid)
                    }
                }

                HStack(spacing: 4) {
                    ForEach(PingHostPreset.allCases) { preset in
                        let selected = store.pingPreset == preset
                        Button {
                            withAnimation(reduceMotion ? nil : AppMotion.snappy) {
                                store.pingPreset = preset
                            }
                        } label: {
                            Text(preset.label)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(selected ? AppColors.accentForeground(for: colorScheme) : Color.secondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 22)
                                .background {
                                    if selected {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(AppColors.accent.opacity(colorScheme == .dark ? 0.22 : 0.14))
                                    }
                                }
                                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                }

                if store.pingPreset == .custom {
                    HStack(spacing: 6) {
                        TextField("Hostname or IPv4 (e.g. apple.com)", text: $store.customPingHost)
                            .textFieldStyle(.plain)
                            .font(AppFont.caption)
                            .onSubmit {
                                if store.isPingHostValid { store.runPing() }
                            }

                        if !store.customPingHost.isEmpty {
                            Image(systemName: store.isPingHostValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(store.isPingHostValid ? AppColors.success : AppColors.critical)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.055))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                (!store.customPingHost.isEmpty && !store.isPingHostValid)
                                    ? AppColors.critical.opacity(0.5)
                                    : AppColors.glassStroke.opacity(0.6),
                                lineWidth: 1
                            )
                    }
                }

                pingBody

                if store.livePingHistory.count >= 2 {
                    let peak = max(store.livePingHistory.max() ?? 100, 20)
                    Sparkline(values: store.livePingHistory.map { min(max($0 / peak, 0), 1) })
                        .frame(height: 22)
                }
            }
        }
    }

    @ViewBuilder
    private var pingBody: some View {
        switch store.pingState {
        case .idle:
            Text("Sends 5 ICMP packets via /sbin/ping to measure latency, jitter, and loss.")
                .font(AppFont.micro)
                .foregroundStyle(.secondary)

        case .running(let host):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Pinging \(host)…")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
            }

        case .completed(let result):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    statBox(
                        title: "Latency",
                        value: result.avgMs.map { String(format: "%.1f ms", $0) } ?? "—"
                    )
                    statBox(
                        title: "Jitter",
                        value: result.jitterMs.map { String(format: "%.1f ms", $0) } ?? "—"
                    )
                    statBox(
                        title: "Loss",
                        value: String(format: "%.0f%%", result.packetLossPercent),
                        tone: result.packetLossPercent >= 20 ? .critical : (result.packetLossPercent > 0 ? .warning : .success)
                    )
                }

                if let minMs = result.minMs, let maxMs = result.maxMs {
                    Text("\(result.host) · \(result.received)/\(result.transmitted) replies · min \(String(format: "%.1f", minMs)) / max \(String(format: "%.1f", maxMs)) ms")
                        .font(AppFont.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("\(result.host) · \(result.received)/\(result.transmitted) replies")
                        .font(AppFont.micro)
                        .foregroundStyle(.secondary)
                }
            }

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(AppFont.micro)
                .foregroundStyle(AppColors.warning)
        }
    }

    // MARK: - Connection & Wi-Fi card

    private var connectionCard: some View {
        let info = store.connectionInfo

        return cardContainer {
            VStack(alignment: .leading, spacing: 7) {
                cardHeader(icon: info.interfaceKind.symbol, title: "Connection")

                detailRow(
                    label: "Interface",
                    value: info.interfaceName.map { "\(info.interfaceKind.rawValue) (\($0))" }
                        ?? info.interfaceKind.rawValue
                )
                detailRow(label: "Local IP", value: info.localIP ?? "Unavailable", monospace: true)
                detailRow(label: "Router IP", value: info.routerIP ?? "Unavailable", monospace: true)
                if !info.dnsServers.isEmpty {
                    detailRow(
                        label: "DNS",
                        value: info.dnsServers.prefix(2).joined(separator: ", "),
                        monospace: true
                    )
                }
                if let vpn = info.vpnInterface {
                    detailRow(label: "VPN Tunnel", value: "Active (\(vpn))", monospace: true)
                }

                if let wifi = info.wifi {
                    Divider().opacity(0.4)

                    HStack(spacing: 6) {
                        Text("Wi-Fi SSID")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)

                        Text(wifi.ssidStatus.displayText)
                            .font(AppFont.caption)
                            .foregroundStyle(wifi.ssidStatus == .hiddenPermissionNeeded ? Color.secondary : Color.primary)
                            .lineLimit(1)

                        if wifi.ssidStatus == .hiddenPermissionNeeded {
                            Button("Allow") {
                                store.requestLocationPermission()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help("macOS requires Location permission to read the Wi-Fi network name")
                        }
                    }

                    detailRow(
                        label: "Signal / Noise",
                        value: formatSignalNoise(wifi),
                        monospace: true
                    )
                    detailRow(
                        label: "Channel & Band",
                        value: wifi.channelSummary,
                        monospace: true
                    )
                }

                Divider().opacity(0.4)

                publicIPRow
            }
        }
    }

    private var publicIPRow: some View {
        HStack(spacing: 6) {
            Text("Public IP")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            switch store.publicIPState {
            case .hidden:
                Text("Hidden")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                Button("Show") {
                    store.togglePublicIP()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Fetches your public IP once on tap")

            case .loading:
                ProgressView()
                    .controlSize(.mini)
                Button("Cancel") {
                    store.togglePublicIP()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

            case .visible(let ip):
                Text(ip)
                    .font(AppFont.number(11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ip, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copy public IP")

                Button("Hide") {
                    store.togglePublicIP()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

            case .failed(let message):
                Text(message)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColors.warning)
                Button("Retry") {
                    store.togglePublicIP()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
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

    private func cardHeader(icon: String, title: String) -> some View {
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

    private func statBox(title: String, value: String, tone: StatusTone = .neutral) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)

            Text(value)
                .font(AppFont.number(12, weight: .semibold))
                .foregroundStyle(tone == .neutral ? Color.primary : tone.color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
    }

    private func detailRow(label: String, value: String, monospace: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(monospace ? AppFont.number(11, weight: .medium) : AppFont.caption)
                .foregroundStyle(value == "Unavailable" ? Color.secondary : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Formatting helpers

    private func formatMbps(_ mbps: Double) -> String {
        if mbps >= 100 { return String(format: "%.0f Mbps", mbps) }
        return String(format: "%.1f Mbps", mbps)
    }

    private func formatCompactMbps(_ mbps: Double) -> String {
        if mbps >= 100 { return String(format: "%.0fM", mbps) }
        return String(format: "%.1fM", mbps)
    }

    private func formatSignalNoise(_ wifi: WiFiDetails) -> String {
        switch (wifi.rssi, wifi.noise) {
        case let (rssi?, noise?):
            return "\(rssi) / \(noise) dBm (SNR \(rssi - noise))"
        case let (rssi?, nil):
            return "\(rssi) dBm"
        case (nil, _):
            return "Unavailable"
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    private func shortTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }
}

#if DEBUG
#Preview("Network Light") {
    NetworkView(
        store: NetworkStore(
            initialConnectionInfo: .preview,
            initialHistory: SpeedTestResult.previewHistory
        ),
        liveSample: NetworkSample(
            downloadBytesPerSecond: 3_400_000,
            uploadBytesPerSecond: 420_000,
            interfaceName: "en0"
        ),
        throughputHistory: [
            ThroughputPoint(downloadBytesPerSecond: 120_000, uploadBytesPerSecond: 40_000),
            ThroughputPoint(downloadBytesPerSecond: 890_000, uploadBytesPerSecond: 120_000),
            ThroughputPoint(downloadBytesPerSecond: 2_400_000, uploadBytesPerSecond: 310_000),
            ThroughputPoint(downloadBytesPerSecond: 1_900_000, uploadBytesPerSecond: 240_000),
            ThroughputPoint(downloadBytesPerSecond: 3_400_000, uploadBytesPerSecond: 420_000)
        ]
    )
    .padding(16)
    .frame(width: 380, height: 440)
    .background(AppBackground())
    .preferredColorScheme(.light)
}

#Preview("Network Dark") {
    NetworkView(
        store: NetworkStore(
            initialConnectionInfo: .preview,
            initialHistory: SpeedTestResult.previewHistory
        ),
        liveSample: NetworkSample(
            downloadBytesPerSecond: 3_400_000,
            uploadBytesPerSecond: 420_000,
            interfaceName: "en0"
        ),
        throughputHistory: [
            ThroughputPoint(downloadBytesPerSecond: 120_000, uploadBytesPerSecond: 40_000),
            ThroughputPoint(downloadBytesPerSecond: 890_000, uploadBytesPerSecond: 120_000),
            ThroughputPoint(downloadBytesPerSecond: 2_400_000, uploadBytesPerSecond: 310_000),
            ThroughputPoint(downloadBytesPerSecond: 3_400_000, uploadBytesPerSecond: 420_000)
        ]
    )
    .padding(16)
    .frame(width: 380, height: 440)
    .background(AppBackground())
    .preferredColorScheme(.dark)
}
#endif
