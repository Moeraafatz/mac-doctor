//
//  MacDoctor/Services/SpeedTestHistoryStore.swift
//  Mac Doctor
//
//  Stores the last 20 speed test results locally in Application Support as
//  JSON. No network or iCloud sync.
//

import Foundation

actor SpeedTestHistoryStore: SpeedTestHistoryStoring {
    static let maxEntries = 20

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.fileURL = base
                .appendingPathComponent("MacDoctor", isDirectory: true)
                .appendingPathComponent("speedtest-history.json")
        }
    }

    func load() async -> [SpeedTestResult] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([SpeedTestResult].self, from: data)
            return Array(decoded.prefix(Self.maxEntries))
        } catch {
            AppLog.network.error("SpeedTestHistoryStore: failed to load history: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func append(_ result: SpeedTestResult) async -> [SpeedTestResult] {
        var current = await load()
        current.insert(result, at: 0)
        if current.count > Self.maxEntries {
            current = Array(current.prefix(Self.maxEntries))
        }
        save(current)
        return current
    }

    func clear() async {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            AppLog.network.error("SpeedTestHistoryStore: failed to clear history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save(_ entries: [SpeedTestResult]) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLog.network.error("SpeedTestHistoryStore: failed to save history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
