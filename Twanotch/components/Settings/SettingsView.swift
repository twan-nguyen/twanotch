//
//  SettingsView.swift
//  Twanotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Sparkle
import SwiftUI

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general
    @State private var accentColorUpdateTrigger = UUID()
    @ObservedObject private var hardware = HardwareCapabilities.shared

    let updaterController: SPUStandardUpdaterController?

    init(updaterController: SPUStandardUpdaterController? = nil) {
        self.updaterController = updaterController
    }

    private var visibleTab: SettingsTab {
        selectedTab == .battery && !hardware.showsBattery ? .general : selectedTab
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                SettingsSidebarHeader()
                ForEach(SettingsTab.sidebarGroups.indices, id: \.self) { index in
                    Section {
                        ForEach(SettingsTab.sidebarGroups[index]) { tab in
                            if tab != .battery || hardware.showsBattery {
                                SettingsSidebarRow(tab: tab)
                                    .tag(tab)
                            }
                        }
                    }
                }
            }
            .listStyle(SidebarListStyle())
            .tint(.effectiveAccent)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(215)
        } detail: {
            VStack(spacing: 0) {
                SettingsPageHeader(tab: visibleTab)
                page(for: visibleTab)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("")
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 760)
        .background(Color(NSColor.windowBackgroundColor))
        .tint(.effectiveAccent)
        .id(accentColorUpdateTrigger)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AccentColorChanged"))) { _ in
            accentColorUpdateTrigger = UUID()
        }
    }

    @ViewBuilder
    private func page(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralSettings()
        case .appearance:
            Appearance()
        case .media:
            Media()
        case .calendar:
            CalendarSettings()
        case .hud:
            HUD()
        case .battery:
            Charge()
        case .shelf:
            Shelf()
        case .claude:
            ClaudeSettings()
        case .shortcuts:
            Shortcuts()
        case .advanced:
            Advanced()
        case .about:
            About(
                updaterController: updaterController
                    ?? SPUStandardUpdaterController(
                        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil))
        }
    }
}
