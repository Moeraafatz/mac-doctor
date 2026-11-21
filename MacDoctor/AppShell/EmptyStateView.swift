//
//  EmptyStateView.swift
//  Mac Doctor
//
//  Deliberately shows no fabricated metrics. Each tab explains what will
//  arrive and what the next implementation step is.
//

import SwiftUI

struct EmptyStateView: View {
    let tab: AppTab

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GlassSurface(cornerRadius: AppRadius.large, contentPadding: 0) {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(AppColors.accent.opacity(0.12))
                        .frame(width: 62, height: 62)

                    Image(systemName: tab.symbol)
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(AppColors.accentForeground(for: colorScheme))
                }

                VitalTrace()
                    .stroke(
                        AppGradients.vitalTrace,
                        style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: 126, height: 14)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text(tab.emptyTitle)
                        .font(AppFont.panelTitle)
                        .foregroundStyle(.primary)

                    Text(tab.emptyMessage)
                        .font(AppFont.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .frame(maxWidth: 250)
                }

                Text(tab.nextStep)
                    .font(AppFont.micro)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background {
                        Capsule()
                            .fill(Color.primary.opacity(0.045))
                    }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .combine)
    }
}
