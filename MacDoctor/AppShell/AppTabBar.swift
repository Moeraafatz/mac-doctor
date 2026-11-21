//
//  MacDoctor/AppShell/AppTabBar.swift
//  Mac Doctor
//
//  Compact five-item black liquid glass segmented control with a glowing
//  Claude-orange matched-geometry selection pill.
//

import SwiftUI

struct AppTabBar: View {
    @Binding var selection: AppTab

    @Namespace private var selectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LiquidGlassGroup(spacing: 8) {
            GlassCapsule {
                HStack(spacing: 2) {
                    ForEach(AppTab.tabBarCases) { tab in
                        TabBarButton(
                            tab: tab,
                            isSelected: selection == tab,
                            namespace: selectionNamespace,
                            reduceMotion: reduceMotion
                        ) {
                            withAnimation(reduceMotion ? nil : AppMotion.snappy) {
                                selection = tab
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct TabBarButton: View {
    let tab: AppTab
    let isSelected: Bool
    let namespace: Namespace.ID
    let reduceMotion: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 12.5, weight: .semibold))

                Text(tab.title)
                    .font(AppFont.tab)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(
                isSelected
                    ? Color.white
                    : Color.white.opacity(isHovering ? 0.85 : 0.50)
            )
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background {
                ZStack {
                    if isSelected {
                        Capsule()
                            .fill(Color.white.opacity(0.15))
                            .overlay {
                                Capsule()
                                    .strokeBorder(
                                        Color.white.opacity(0.28),
                                        lineWidth: 1
                                    )
                            }
                            .shadow(color: Color.black.opacity(0.30), radius: 6, x: 0, y: 2)
                            .matchedGeometryEffect(id: "selected-tab", in: namespace)
                    } else if isHovering {
                        Capsule()
                            .fill(Color.white.opacity(0.06))
                    }
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityLabel(tab.accessibilityTitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(tab.accessibilityTitle)
    }
}
