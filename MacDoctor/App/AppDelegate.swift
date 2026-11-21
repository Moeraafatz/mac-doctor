//
//  AppDelegate.swift
//  Mac Doctor
//
//  Keeps Mac Doctor as an accessory app with no Dock icon, even if the
//  LSUIElement key is ever accidentally removed from a development build.
//

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppLog.lifecycle.info("Mac Doctor launched")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.lifecycle.info("Mac Doctor terminating")
    }
}
