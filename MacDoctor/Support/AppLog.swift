//
//  AppLog.swift
//  Mac Doctor
//
//  Centralized os.Logger categories. Every data source added in later
//  phases must log failures here instead of silently swallowing errors.
//

import os

enum AppLog {
    private static let subsystem = "com.macdoctor.app"

    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let sensors = Logger(subsystem: subsystem, category: "sensors")
    static let processes = Logger(subsystem: subsystem, category: "processes")
    static let network = Logger(subsystem: subsystem, category: "network")
}
