//
//  MacDoctor/Services/ProcessController.swift
//  Mac Doctor
//
//  Executes Quit, Force Quit, and Finder Relaunch actions.
//
//  Defense-in-depth safety checks run right before every signal:
//  • Re-verifies the hard blocklist against both the UI entry and live kernel
//    process info (guards against PID reuse).
//  • Re-verifies `pbi_uid == getuid()` so only processes owned by the current
//    user can ever be signalled.
//  • GUI apps use `NSRunningApplication.terminate()` / `forceTerminate()`.
//  • Background processes use `SIGTERM`, then `SIGKILL` only after a second
//    confirmation in the UI.
//  • Finder is never killed with SIGKILL; it only supports graceful relaunch.
//

import AppKit
import Darwin
import Foundation

struct ProcessController: ProcessControlling {
    func quit(_ entry: ProcessEntry) async -> ProcessActionResult {
        if let blocked = verifyAllowed(entry) {
            return blocked
        }

        if entry.isGUIApp {
            let result = await terminateGUIApp(pid: entry.pid, name: entry.name, force: false)
            if let result { return result }
        }

        return sendSignal(SIGTERM, to: entry, actionName: "Quit (SIGTERM)")
    }

    func forceQuit(_ entry: ProcessEntry) async -> ProcessActionResult {
        if let blocked = verifyAllowed(entry) {
            return blocked
        }

        if entry.isGUIApp {
            let result = await terminateGUIApp(pid: entry.pid, name: entry.name, force: true)
            if let result { return result }
        }

        return sendSignal(SIGKILL, to: entry, actionName: "Force Quit (SIGKILL)")
    }

    func relaunchFinder() async -> ProcessActionResult {
        let terminated = await MainActor.run { () -> Bool in
            let finders = NSRunningApplication.runningApplications(
                withBundleIdentifier: ProcessBlocklist.finderBundleIdentifier
            )
            guard !finders.isEmpty else { return false }
            return finders.allSatisfy { $0.terminate() }
        }

        if !terminated {
            AppLog.processes.error("ProcessController: Finder terminate() returned false")
            return .failed("Could not ask Finder to relaunch.")
        }

        AppLog.processes.notice("ProcessController: requested Finder relaunch")

        // macOS launchd automatically restarts Finder. Wait briefly and open it
        // explicitly if launchd has not already respawned it.
        try? await Task.sleep(for: .milliseconds(900))

        let isRunning = await MainActor.run {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: ProcessBlocklist.finderBundleIdentifier
            ).isEmpty
        }

        if !isRunning {
            let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            do {
                _ = try await NSWorkspace.shared.openApplication(at: finderURL, configuration: config)
            } catch {
                AppLog.processes.error("ProcessController: failed to reopen Finder: \(error.localizedDescription, privacy: .public)")
                return .failed("Finder closed but could not be reopened automatically.")
            }
        }

        return .succeeded("Finder relaunched.")
    }

    // MARK: - Defense-in-depth verification

    private func verifyAllowed(_ entry: ProcessEntry) -> ProcessActionResult? {
        let currentUID = getuid()
        let selfPID = ProcessInfo.processInfo.processIdentifier

        // Check policy on the snapshot entry first.
        let entryPolicy = ProcessBlocklist.policy(
            pid: entry.pid,
            executableName: entry.executableName,
            displayName: entry.name,
            bundleIdentifier: entry.bundleIdentifier,
            uid: entry.uid,
            currentUID: currentUID,
            selfPID: selfPID
        )
        switch entryPolicy {
        case .allowed:
            break
        case .relaunchOnly(let reason), .blocked(let reason):
            AppLog.processes.notice("ProcessController: blocked action on PID \(entry.pid): \(reason, privacy: .public)")
            return .blocked(reason)
        }

        // Re-read live BSD info from the kernel to verify the PID still exists,
        // is still owned by the current user, and hasn't been recycled into a
        // protected system process.
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(entry.pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else {
            return .succeeded("\(entry.name) has already exited.")
        }

        let liveName = liveProcessName(pid: entry.pid, bsd: bsd)
        let livePolicy = ProcessBlocklist.policy(
            pid: entry.pid,
            executableName: liveName,
            displayName: liveName,
            bundleIdentifier: nil,
            uid: bsd.pbi_uid,
            currentUID: currentUID,
            selfPID: selfPID
        )
        switch livePolicy {
        case .allowed:
            return nil
        case .relaunchOnly(let reason), .blocked(let reason):
            AppLog.processes.notice("ProcessController: live re-check blocked PID \(entry.pid): \(reason, privacy: .public)")
            return .blocked(reason)
        }
    }

    @MainActor
    private func terminateGUIApp(pid: pid_t, name: String, force: Bool) -> ProcessActionResult? {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return nil
        }

        let ok = force ? app.forceTerminate() : app.terminate()
        let verb = force ? "Force quit" : "Sent Quit to"
        if ok {
            AppLog.processes.notice("ProcessController: \(verb, privacy: .public) GUI app \(name, privacy: .public) (PID \(pid))")
            return .succeeded("\(verb) \(name) (PID \(pid)).")
        }

        AppLog.processes.error("ProcessController: NSRunningApplication \(force ? "forceTerminate" : "terminate", privacy: .public) failed for PID \(pid)")
        return .failed("Could not \(force ? "force quit" : "quit") \(name) (PID \(pid)).")
    }

    private func sendSignal(_ signal: Int32, to entry: ProcessEntry, actionName: String) -> ProcessActionResult {
        if Darwin.kill(entry.pid, signal) == 0 {
            AppLog.processes.notice("ProcessController: \(actionName, privacy: .public) sent to \(entry.name, privacy: .public) (PID \(entry.pid))")
            return .succeeded("\(actionName) sent to \(entry.name) (PID \(entry.pid)).")
        }

        let code = errno
        if code == ESRCH {
            return .succeeded("\(entry.name) has already exited.")
        }

        let message = String(cString: strerror(code))
        AppLog.processes.error("ProcessController: \(actionName, privacy: .public) failed for PID \(entry.pid): \(message, privacy: .public)")
        return .failed("Could not end \(entry.name) (PID \(entry.pid)): \(message).")
    }

    private func liveProcessName(pid: pid_t, bsd: proc_bsdinfo) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        if length > 0 {
            let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
            let name = String(decoding: bytes, as: UTF8.self)
            if !name.isEmpty { return name }
        }
        return withUnsafeBytes(of: bsd.pbi_name) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
