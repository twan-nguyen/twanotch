//
//  TabSelectionView.swift
//  Twanotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: LocalizedStringKey
    let icon: String
    let view: NotchViews
}

let tabs = [
    TabModel(label: "Home", icon: "house.fill", view: .home),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf),
    TabModel(label: "Claude", icon: ClaudeMascot.tabIcon, view: .claude)
]

/// Whether Home has anything to show: a player that is playing or paused, or the calendar.
@MainActor var homeHasContent: Bool {
    !MusicManager.shared.hasNoMediaSource || Defaults[.showCalendar]
}

/// Whether the header shows the tab bar; it hides it for an empty shelf unless tabs always show.
@MainActor var showsTabBar: Bool {
    let shelfTabs = !ShelfStateViewModel.shared.isEmpty || NotchViewCoordinator.shared.alwaysShowTabs
    return (shelfTabs && Defaults[.shelfEnabled]) || Defaults[.showClaudeUsage]
}

/// The tabs the open notch offers right now. Home steps aside while it has nothing to show,
/// as long as the tab bar is there to reach the others.
@MainActor func visibleNotchViews() -> [NotchViews] {
    let others = tabs.map(\.view).filter { view in
        switch view {
        case .home: false
        case .shelf: Defaults[.shelfEnabled]
        case .claude: Defaults[.showClaudeUsage]
        }
    }
    return homeHasContent || others.isEmpty || !showsTabBar ? [.home] + others : others
}

struct TabSelectionView: View {
    @ObservedObject var coordinator = NotchViewCoordinator.shared
    @ObservedObject private var musicManager = MusicManager.shared
    @ObservedObject private var claudeUsage = ClaudeUsageManager.shared
    @ObservedObject private var claudePrompts = ClaudePromptCenter.shared
    @ObservedObject private var shelf = ShelfStateViewModel.shared
    @Namespace var animation
    @Default(.shelfEnabled) var shelfEnabled
    @Default(.showClaudeUsage) var showClaudeUsage
    @Default(.showCalendar) var showCalendar

    private var visibleTabs: [TabModel] {
        // Reading the defaults here keeps the bar in step when they change.
        _ = (shelfEnabled, showClaudeUsage, showCalendar, musicManager.hasNoMediaSource)
        let views = visibleNotchViews()
        return tabs.filter { views.contains($0.view) }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs) { tab in
                let selected = coordinator.currentView == tab.view
                TabButton(label: tab.label, icon: icon(for: tab), selected: selected) {
                    withAnimation(.smooth) {
                        coordinator.currentView = tab.view
                    }
                }
                .frame(height: 26)
                .foregroundStyle(selected ? NotchTheme.primaryText : NotchTheme.secondaryText)
                .overlay(alignment: .topTrailing) {
                    if let badge = badge(for: tab.view) {
                        Circle()
                            .fill(badge)
                            .frame(width: 6, height: 6)
                            .padding(.top, 3)
                            .padding(.trailing, 9)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .background {
                    if selected {
                        Capsule()
                            .fill(NotchTheme.Fill.control)
                            .matchedGeometryEffect(id: "capsule", in: animation)
                    }
                }
            }
        }
        .clipShape(Capsule())
        .animation(.smooth, value: badge(for: .claude))
    }

    /// The shelf tab shows a full tray while it holds items.
    private func icon(for tab: TabModel) -> String {
        tab.view == .shelf && !shelf.isEmpty ? "tray.full.fill" : tab.icon
    }

    /// A dot on the Claude tab while a prompt waits or the 5-hour session is running low.
    private func badge(for view: NotchViews) -> Color? {
        guard view == .claude else { return nil }
        if claudePrompts.current != nil { return ClaudeMascot.tint }
        return claudeUsage.session?.remainingTint
    }
}

#Preview {
    NotchHeader().environmentObject(NotchViewModel())
}
