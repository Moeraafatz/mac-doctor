//
//  MacDoctor/Views/Processes/ProcessConfirmationSheet.swift
//  Mac Doctor
//
//  Confirmation sheet shown before quitting, force-quitting, or relaunching
//  Finder. Always displays the process name, PID, mechanism, and an explicit
//  warning about unsaved work.
//

import AppKit
import SwiftUI

struct ProcessConfirmationSheet: View {
    let action: PendingProcessAction
    let icon: NSImage
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var isDestructive: Bool {
        action.kind == .forceQuit
    }

    private var accentColor: Color {
        switch action.kind {
        case .quit: AppColors.warning
        case .forceQuit: AppColors.critical
        case .relaunchFinder: AppColors.accent
        }
    }

    private var mechanismDetail: String {
        switch action.kind {
        case .quit:
            return action.entry.isGUIApp
                ? "Sends a normal Quit request (NSRunningApplication.terminate) so the app can prompt to save documents."
                : "Sends SIGTERM so the background process can shut down cleanly. If it keeps running, you can confirm Force Quit (SIGKILL) next."
        case .forceQuit:
            return action.entry.isGUIApp
                ? "Immediately ends the app with forceTerminate(). The app will not have a chance to save open files."
                : "Second confirmation: immediately kills the process with SIGKILL. The process cannot clean up or flush buffers."
        case .relaunchFinder:
            return "Asks Finder to quit and reopen. Finder cannot be force-killed from Mac Doctor."
        }
    }

    private var unsavedWorkWarning: String {
        switch action.kind {
        case .quit:
            return "Any unsaved work in \(action.entry.name) could be lost if the process closes without prompting."
        case .forceQuit:
            return "All unsaved work in \(action.entry.name) will be permanently lost."
        case .relaunchFinder:
            return "Open Finder windows will reopen, but any in-progress file copies or transfers may be interrupted."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Image(systemName: isDestructive ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(accentColor)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-1))
                        .offset(x: 3, y: 3)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(action.kind.title)
                        .font(AppFont.panelTitle)
                        .foregroundStyle(.primary)

                    Text("\(action.entry.name)  ·  PID \(String(action.entry.pid))")
                        .font(AppFont.number(11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            Text(mechanismDetail)
                .font(AppFont.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .padding(.top, 1)

                Text(unsavedWorkWarning)
                    .font(AppFont.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(accentColor.opacity(0.11))
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .strokeBorder(accentColor.opacity(0.28), lineWidth: 1)
            }

            HStack(spacing: 8) {
                Spacer()

                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button(action.kind.confirmButtonLabel, role: isDestructive ? .destructive : nil, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(accentColor)
            }
        }
        .padding(18)
        .frame(width: 332)
    }
}
