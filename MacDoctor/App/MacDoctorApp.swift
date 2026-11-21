//
//  MacDoctor/App/MacDoctorApp.swift
//  Mac Doctor
//
//  Menu-bar-only application entry point. Owns the shared SettingsStore and
//  VitalsStore so the MenuBarExtra label stays live (readout + amber/red
//  threshold tinting + optional notifications) even while the popover is closed.
//

import SwiftUI

@main
struct MacDoctorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: SettingsStore
    @State private var vitals: VitalsStore

    init() {
        let notifier = AlertNotificationService()
        let settings = SettingsStore(notifier: notifier)
        let vitals = VitalsStore(settings: settings, notifier: notifier)
        _settings = State(initialValue: settings)
        _vitals = State(initialValue: vitals)
    }

    var body: some Scene {
        MenuBarExtra {
            AppShellView(vitals: vitals, settings: settings)
        } label: {
            MenuBarLabelView(vitals: vitals, settings: settings)
        }
        .menuBarExtraStyle(.window)
    }
}
