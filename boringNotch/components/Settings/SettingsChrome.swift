//
//  SettingsChrome.swift
//  boringNotch
//
//  Sidebar, icons and page headers that give the settings window a System Settings look.
//

import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, media, calendar, hud, battery, shelf, shortcuts, advanced, about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .media: "Media"
        case .calendar: "Calendar"
        case .hud: "HUDs"
        case .battery: "Battery"
        case .shelf: "Shelf"
        case .shortcuts: "Shortcuts"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var summary: LocalizedStringKey {
        switch self {
        case .general: "Language, startup, displays and how the notch opens."
        case .appearance: "Look of the notch, music visualizer and mirror."
        case .media: "Music source, playback controls and live activity."
        case .calendar: "Calendars and reminders shown in the notch."
        case .hud: "Replace the system volume and brightness indicators."
        case .battery: "Battery indicator and charging notifications."
        case .shelf: "Temporary file shelf, AirDrop and quick sharing."
        case .shortcuts: "Keyboard shortcuts for controlling the notch."
        case .advanced: "Accent color, window behavior and extra options."
        case .about: "Version, credits and source code."
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintbrush.fill"
        case .media: "music.note"
        case .calendar: "calendar"
        case .hud: "slider.horizontal.3"
        case .battery: "battery.100.bolt"
        case .shelf: "tray.full.fill"
        case .shortcuts: "command"
        case .advanced: "wrench.and.screwdriver.fill"
        case .about: "info"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .appearance: .indigo
        case .media: .pink
        case .calendar: .red
        case .hud: .blue
        case .battery: .green
        case .shelf: .orange
        case .shortcuts: Color(white: 0.45)
        case .advanced: .purple
        case .about: .teal
        }
    }

    /// Sidebar grouping, mirroring the section breaks in System Settings.
    static let sidebarGroups: [[SettingsTab]] = [
        [.general, .appearance],
        [.media, .calendar, .hud, .battery, .shelf],
        [.shortcuts, .advanced],
        [.about],
    ]
}

/// Rounded, filled icon tile like the ones in the System Settings sidebar.
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
    }
}

struct SettingsSidebarRow: View {
    let tab: SettingsTab

    var body: some View {
        Label {
            Text(tab.title)
        } icon: {
            SettingsIcon(symbol: tab.symbol, color: tab.color)
        }
    }
}

/// App identity card shown at the top of the sidebar.
struct SettingsSidebarHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("Twanotch")
                    .font(.headline)
                Text("Version \(Bundle.main.releaseVersionNumber ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

/// Hero header at the top of each settings page.
struct SettingsPageHeader: View {
    let tab: SettingsTab

    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(symbol: tab.symbol, color: tab.color, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(tab.title)
                    .font(.title2.weight(.semibold))
                Text(tab.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }
}
