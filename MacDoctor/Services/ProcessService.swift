//
//  MacDoctor/Services/ProcessService.swift
//  Mac Doctor
//
//  Samples running processes off the main thread using Darwin libproc
//  (`proc_listallpids`, `proc_pidinfo`, `proc_pid_rusage`) and optional
//  per-process network counters from `NettopRunner`.
//
//  CPU % is computed from monotonic `ri_user_time + ri_system_time` deltas
//  converted to nanoseconds via `mach_timebase_info`.
//  Energy uses `rusage_info_v6.ri_energy_nj` deltas when reported by the
//  kernel, falling back to an explicitly labelled estimate from CPU %,
//  idle wakeups, and disk I/O when `ri_energy_nj` is unavailable.
//

import AppKit
import Darwin
import Foundation

actor ProcessService: ProcessSampling {
    private struct ProcessIdentity: Hashable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicros: UInt64
    }

    private struct PreviousSample {
        let cpuTicks: UInt64
        let energyNanojoules: UInt64
        let sawRealEnergy: Bool
        let idleWakeups: UInt64
        let diskBytes: UInt64
        let timestampNanoseconds: UInt64
    }

    private struct RunningAppInfo: Sendable {
        let localizedName: String?
        let bundleIdentifier: String?
        let bundleURL: URL?
        let isGUIApp: Bool
    }

    private struct CachedNettop {
        let counters: [pid_t: NettopCounter]
        let rates: [pid_t: (inPerSec: Double, outPerSec: Double)]
        let capturedAtNanoseconds: UInt64
    }

    private struct CachedMetadata {
        let executableName: String
        let executablePath: String?
    }

    private let nettop: any NettopSampling
    private let nettopMinIntervalNanoseconds: UInt64
    private let timebaseScale: Double
    private let currentUID: uid_t
    private let selfPID: pid_t

    private var metadataCache: [ProcessIdentity: CachedMetadata] = [:]
    private var previousByIdentity: [ProcessIdentity: PreviousSample] = [:]
    private var highCPUSince: [ProcessIdentity: Date] = [:]
    private var memoryBaseline: [ProcessIdentity: (bytes: UInt64, date: Date)] = [:]
    private var lastNettop: CachedNettop?
    private var nettopAvailable = true

    init(
        nettop: any NettopSampling = NettopRunner(),
        nettopMinInterval: Duration = .seconds(6)
    ) {
        self.nettop = nettop
        let components = nettopMinInterval.components
        self.nettopMinIntervalNanoseconds = UInt64(max(0, components.seconds)) * 1_000_000_000
            + UInt64(max(0, components.attoseconds) / 1_000_000_000)

        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        self.timebaseScale = info.denom > 0 ? Double(info.numer) / Double(info.denom) : 1.0
        self.currentUID = getuid()
        self.selfPID = ProcessInfo.processInfo.processIdentifier
    }

    func sample(includeNetwork: Bool) async -> ProcessSnapshot {
        let nowDate = Date()
        let nowNs = DispatchTime.now().uptimeNanoseconds

        async let appLookupTask = Self.snapshotRunningApps()
        async let nettopTask: CachedNettop? = fetchNettopIfNeeded(
            includeNetwork: includeNetwork,
            nowNs: nowNs
        )

        let pids = Self.listAllPIDs()
        let runningApps = await appLookupTask
        let nettopState = await nettopTask

        var nextPrevious: [ProcessIdentity: PreviousSample] = [:]
        nextPrevious.reserveCapacity(pids.count)

        var activeIdentities: Set<ProcessIdentity> = []
        activeIdentities.reserveCapacity(pids.count)

        var entries: [ProcessEntry] = []
        entries.reserveCapacity(pids.count)

        var offenders: [ProcessOffender] = []
        var anyEstimatedEnergy = false

        for pid in pids where pid >= 0 {
            guard let bsd = Self.readBSDInfo(pid) else { continue }

            let identity = ProcessIdentity(
                pid: pid,
                startSeconds: bsd.pbi_start_tvsec,
                startMicros: bsd.pbi_start_tvusec
            )
            activeIdentities.insert(identity)

            let meta: CachedMetadata
            if let cached = metadataCache[identity] {
                meta = cached
            } else {
                let execName = Self.processName(pid: pid, bsd: bsd)
                let execPath = Self.processPath(pid)
                meta = CachedMetadata(executableName: execName, executablePath: execPath)
                metadataCache[identity] = meta
            }

            let execName = meta.executableName
            let appInfo = runningApps[pid]
            let displayName: String = {
                if let localized = appInfo?.localizedName, !localized.isEmpty {
                    return localized
                }
                return execName
            }()

            let executablePath = meta.executablePath
            // Non-root callers receive EPERM for other UIDs on both rusage and
            // taskinfo; skip those ~300 guaranteed-EPERM kernel traps per tick.
            let isOwnProcess = (bsd.pbi_uid == currentUID)
            let rusage = isOwnProcess ? Self.readRusage(pid) : nil
            let taskInfo = (isOwnProcess && rusage == nil) ? Self.readTaskInfo(pid) : nil

            let cpuTicks: UInt64?
            let memoryBytes: UInt64
            let energyNj: UInt64
            let idleWakeups: UInt64
            let diskBytes: UInt64
            let hasRusage: Bool

            if let ru = rusage {
                hasRusage = true
                cpuTicks = ru.ri_user_time &+ ru.ri_system_time
                memoryBytes = ru.ri_phys_footprint > 0 ? ru.ri_phys_footprint : ru.ri_resident_size
                energyNj = ru.ri_energy_nj
                idleWakeups = ru.ri_pkg_idle_wkups
                diskBytes = ru.ri_diskio_bytesread &+ ru.ri_diskio_byteswritten
            } else if let ti = taskInfo {
                hasRusage = false
                cpuTicks = ti.pti_total_user &+ ti.pti_total_system
                memoryBytes = ti.pti_resident_size
                energyNj = 0
                idleWakeups = 0
                diskBytes = 0
            } else {
                hasRusage = false
                cpuTicks = nil
                memoryBytes = 0
                energyNj = 0
                idleWakeups = 0
                diskBytes = 0
            }

            var cpuPercent: Double = 0
            var energy: ProcessEnergy = .unavailable

            if let cpuTicks {
                let prev = previousByIdentity[identity]
                let sawRealEnergy = (prev?.sawRealEnergy ?? false) || (hasRusage && energyNj > 0)

                if let prev, nowNs > prev.timestampNanoseconds {
                    let elapsedNs = Double(nowNs - prev.timestampNanoseconds)
                    let elapsedSeconds = elapsedNs / 1_000_000_000

                    if cpuTicks >= prev.cpuTicks {
                        let deltaCpuNs = Double(cpuTicks - prev.cpuTicks) * timebaseScale
                        cpuPercent = max(0, (deltaCpuNs / elapsedNs) * 100.0)
                    }

                    if hasRusage && sawRealEnergy && energyNj >= prev.energyNanojoules {
                        // 1 nJ / 1 ns = 1 W.
                        let watts = Double(energyNj - prev.energyNanojoules) / elapsedNs
                        energy = .measuredWatts(max(0, watts))
                    } else if elapsedSeconds > 0 {
                        // Fallback estimate when `ri_energy_nj` is unavailable.
                        let deltaWakeups = idleWakeups >= prev.idleWakeups
                            ? Double(idleWakeups - prev.idleWakeups) / elapsedSeconds
                            : 0
                        let deltaDiskMB = diskBytes >= prev.diskBytes
                            ? Double(diskBytes - prev.diskBytes) / (1_000_000 * elapsedSeconds)
                            : 0
                        let score = max(0, cpuPercent * 0.5 + deltaWakeups * 0.02 + deltaDiskMB * 0.5)
                        energy = .estimated(score)
                        anyEstimatedEnergy = true
                    }
                }

                nextPrevious[identity] = PreviousSample(
                    cpuTicks: cpuTicks,
                    energyNanojoules: energyNj,
                    sawRealEnergy: sawRealEnergy,
                    idleWakeups: idleWakeups,
                    diskBytes: diskBytes,
                    timestampNanoseconds: nowNs
                )
            }

            // Track consecutive >50% CPU duration for Top Offenders banner.
            let sustainedSeconds: TimeInterval
            if cpuPercent >= ProcessThresholds.sustainedCPUPercent {
                let since = highCPUSince[identity] ?? nowDate
                highCPUSince[identity] = since
                sustainedSeconds = nowDate.timeIntervalSince(since)
            } else {
                highCPUSince.removeValue(forKey: identity)
                sustainedSeconds = 0
            }

            let netCounters = nettopState?.counters[pid]
            let netRate = nettopState?.rates[pid]

            var reasons: [OffenderReason] = []
            if sustainedSeconds >= ProcessThresholds.sustainedCPUDuration {
                reasons.append(.sustainedCPU(percent: cpuPercent, duration: sustainedSeconds))
            }
            if energy.isHighEnergy {
                reasons.append(.highEnergy(label: energy.compactLabel, isEstimated: energy.isEstimated))
            }
            if let netRate {
                let combined = netRate.inPerSec + netRate.outPerSec
                if combined >= ProcessThresholds.heavyNetworkBytesPerSecond {
                    reasons.append(.heavyNetwork(bytesPerSecond: combined))
                }
            }

            // Rolling 5-minute memory-growth watchdog.
            if memoryBytes > 0 {
                if let base = memoryBaseline[identity] {
                    if nowDate.timeIntervalSince(base.date) > ProcessThresholds.memoryGrowthWindowSeconds {
                        memoryBaseline[identity] = (memoryBytes, nowDate)
                    } else if memoryBytes > base.bytes {
                        let growth = memoryBytes - base.bytes
                        if growth >= ProcessThresholds.memoryGrowthBytes {
                            reasons.append(.memoryGrowth(deltaBytes: growth))
                        }
                    } else if memoryBytes < base.bytes {
                        // Track lowest memory seen in the current window.
                        memoryBaseline[identity] = (memoryBytes, base.date)
                    }
                } else {
                    memoryBaseline[identity] = (memoryBytes, nowDate)
                }
            }

            let policy = ProcessBlocklist.policy(
                pid: pid,
                executableName: execName,
                displayName: displayName,
                bundleIdentifier: appInfo?.bundleIdentifier,
                uid: bsd.pbi_uid,
                currentUID: currentUID,
                selfPID: selfPID
            )

            let entry = ProcessEntry(
                pid: pid,
                name: displayName,
                executableName: execName,
                executablePath: executablePath,
                bundleURL: appInfo?.bundleURL,
                bundleIdentifier: appInfo?.bundleIdentifier,
                uid: bsd.pbi_uid,
                isGUIApp: appInfo?.isGUIApp ?? false,
                cpuPercent: cpuPercent,
                memoryBytes: memoryBytes,
                energy: energy,
                networkBytesInPerSec: netRate?.inPerSec,
                networkBytesOutPerSec: netRate?.outPerSec,
                networkTotalBytesIn: netCounters?.bytesIn,
                networkTotalBytesOut: netCounters?.bytesOut,
                sustainedHighCPUSeconds: sustainedSeconds,
                policy: policy,
                offenderReasons: reasons
            )

            entries.append(entry)

            if !reasons.isEmpty {
                offenders.append(ProcessOffender(pid: pid, name: displayName, reasons: reasons))
            }
        }

        previousByIdentity = nextPrevious
        metadataCache = metadataCache.filter { activeIdentities.contains($0.key) }
        highCPUSince = highCPUSince.filter { activeIdentities.contains($0.key) }
        memoryBaseline = memoryBaseline.filter { activeIdentities.contains($0.key) }

        offenders.sort { lhs, rhs in
            let lCount = lhs.reasons.count
            let rCount = rhs.reasons.count
            if lCount != rCount { return lCount > rCount }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return ProcessSnapshot(
            processes: entries,
            offenders: offenders,
            nettopAvailable: nettopAvailable,
            anyEstimatedEnergy: anyEstimatedEnergy,
            capturedAt: nowDate
        )
    }

    // MARK: - Nettop throttling and delta calculation

    private func fetchNettopIfNeeded(includeNetwork: Bool, nowNs: UInt64) async -> CachedNettop? {
        guard includeNetwork else { return lastNettop }

        if let lastNettop,
           nowNs >= lastNettop.capturedAtNanoseconds,
           (nowNs - lastNettop.capturedAtNanoseconds) < nettopMinIntervalNanoseconds {
            return lastNettop
        }

        guard let counters = await nettop.sample() else {
            nettopAvailable = false
            return lastNettop
        }

        nettopAvailable = true
        let sampleTime = DispatchTime.now().uptimeNanoseconds

        var rates: [pid_t: (inPerSec: Double, outPerSec: Double)] = [:]
        if let prev = lastNettop, sampleTime > prev.capturedAtNanoseconds {
            let elapsedSeconds = Double(sampleTime - prev.capturedAtNanoseconds) / 1_000_000_000
            if elapsedSeconds > 0 {
                rates.reserveCapacity(counters.count)
                for (pid, current) in counters {
                    guard let old = prev.counters[pid] else { continue }
                    let deltaIn = current.bytesIn >= old.bytesIn ? Double(current.bytesIn - old.bytesIn) : 0
                    let deltaOut = current.bytesOut >= old.bytesOut ? Double(current.bytesOut - old.bytesOut) : 0
                    rates[pid] = (deltaIn / elapsedSeconds, deltaOut / elapsedSeconds)
                }
            }
        }

        let updated = CachedNettop(
            counters: counters,
            rates: rates,
            capturedAtNanoseconds: sampleTime
        )
        lastNettop = updated
        return updated
    }

    // MARK: - Darwin libproc helpers

    private static func listAllPIDs() -> [pid_t] {
        // `proc_listallpids` returns the number of PIDs (not bytes).
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return [] }

        let capacity = Int(estimatedCount) + 64
        var buffer = [pid_t](repeating: 0, count: capacity)
        let bufferBytes = Int32(capacity * MemoryLayout<pid_t>.stride)
        let actualCount = proc_listallpids(&buffer, bufferBytes)
        guard actualCount > 0 else { return [] }

        return Array(buffer.prefix(min(Int(actualCount), capacity)))
    }

    private static func readBSDInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let returned = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard returned == size else { return nil }
        return info
    }

    private static func readRusage(_ pid: pid_t) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V6, rebound)
            }
        }
        return status == 0 ? info : nil
    }

    private static func readTaskInfo(_ pid: pid_t) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        let returned = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard returned == size else { return nil }
        return info
    }

    private static func processPath(_ pid: pid_t) -> String? {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(MAXPATHLEN) * 4) { buf in
            guard let base = buf.baseAddress else { return nil }
            let length = proc_pidpath(pid, base, UInt32(buf.count))
            guard length > 0 else { return nil }
            let raw = UnsafeRawBufferPointer(start: base, count: Int(length))
            return String(decoding: raw, as: UTF8.self)
        }
    }

    private static func processName(pid: pid_t, bsd: proc_bsdinfo) -> String {
        let found: String? = withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(MAXPATHLEN)) { buf in
            guard let base = buf.baseAddress else { return nil }
            let length = proc_name(pid, base, UInt32(buf.count))
            guard length > 0 else { return nil }
            let raw = UnsafeRawBufferPointer(start: base, count: Int(length))
            let name = String(decoding: raw, as: UTF8.self)
            return name.isEmpty ? nil : name
        }
        if let found { return found }

        let bsdName = cString(from: bsd.pbi_name)
        if !bsdName.isEmpty { return bsdName }

        let comm = cString(from: bsd.pbi_comm)
        if !comm.isEmpty { return comm }

        return "PID \(pid)"
    }

    private static func cString<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let prefix = raw.prefix { $0 != 0 }
            return String(decoding: prefix, as: UTF8.self)
        }
    }

    @MainActor
    private static func snapshotRunningApps() -> [pid_t: RunningAppInfo] {
        var map: [pid_t: RunningAppInfo] = [:]
        for app in NSWorkspace.shared.runningApplications {
            let isGUI = app.activationPolicy == .regular || app.activationPolicy == .accessory
            map[app.processIdentifier] = RunningAppInfo(
                localizedName: app.localizedName,
                bundleIdentifier: app.bundleIdentifier,
                bundleURL: app.bundleURL,
                isGUIApp: isGUI
            )
        }
        return map
    }
}
