//
//  MacDoctor/Services/SleepAssertionService.swift
//  Mac Doctor
//
//  Reads active macOS power assertions via Apple's public IOKit API
//  `IOPMCopyAssertionsByProcess` (no subprocess, no root). Surfaces apps
//  currently preventing idle or display sleep.
//

import Foundation
import IOKit
import IOKit.pwr_mgt

actor SleepAssertionService: SleepAssertionSampling {
    private static let displaySleepTypes: Set<String> = [
        "NoDisplaySleepAssertion",
        "PreventUserIdleDisplaySleep"
    ]

    private static let systemSleepTypes: Set<String> = [
        "NoIdleSleepAssertion",
        "PreventUserIdleSystemSleep",
        "PreventSystemSleep"
    ]

    /// Internal macOS power daemon assertions that are always present while
    /// the screen is on and would otherwise create noise.
    private static let ignoredProcessNames: Set<String> = [
        "powerd"
    ]

    func sample() async -> [SleepBlocker] {
        var unmanaged: Unmanaged<CFDictionary>?
        let status = IOPMCopyAssertionsByProcess(&unmanaged)
        guard status == kIOReturnSuccess,
              let dict = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else {
            return []
        }

        var byPID: [pid_t: SleepBlocker] = [:]

        for (pidNumber, assertions) in dict {
            let pid = pid_t(pidNumber.int32Value)
            guard pid > 0 else { continue }

            for item in assertions {
                guard let type = item["AssertType"] as? String else { continue }
                let blocksDisplay = Self.displaySleepTypes.contains(type)
                let blocksSystem = Self.systemSleepTypes.contains(type)
                guard blocksDisplay || blocksSystem else { continue }

                let processName = (item["Process Name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "PID \(pid)"
                guard !Self.ignoredProcessNames.contains(processName) else { continue }

                let rawReason = (item["AssertName"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let reason = rawReason.isEmpty
                    ? (blocksDisplay ? "Preventing display sleep" : "Preventing system sleep")
                    : rawReason

                let candidate = SleepBlocker(
                    pid: pid,
                    processName: processName,
                    reason: reason,
                    blocksDisplay: blocksDisplay
                )

                // Keep one entry per PID, preferring display-sleep blockers.
                if let existing = byPID[pid] {
                    if !existing.blocksDisplay && candidate.blocksDisplay {
                        byPID[pid] = candidate
                    }
                } else {
                    byPID[pid] = candidate
                }
            }
        }

        return byPID.values.sorted { lhs, rhs in
            if lhs.blocksDisplay != rhs.blocksDisplay {
                return lhs.blocksDisplay
            }
            return lhs.processName.localizedCaseInsensitiveCompare(rhs.processName) == .orderedAscending
        }
    }
}
