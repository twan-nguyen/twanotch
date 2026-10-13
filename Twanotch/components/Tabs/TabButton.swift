//
//  TabButton.swift
//  Twanotch
//
//  Created by Hugo Persson on 2024-08-24.
//

import SwiftUI

struct TabButton: View {
    let label: LocalizedStringKey
    let icon: String
    let selected: Bool
    let onClick: () -> Void
    
    var body: some View {
        Button(action: onClick) {
            iconView
                .padding(.horizontal, 15)
                .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
        .help(label)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var iconView: some View {
        if icon == ClaudeMascot.tabIcon {
            ClaudeMascot()
                .fill(selected ? ClaudeMascot.tint : ClaudeMascot.tint.opacity(0.6))
                .frame(width: 18, height: 12)
        } else {
            Image(systemName: icon)
        }
    }
}

#Preview {
    TabButton(label: "Home", icon: "tray.fill", selected: true) {
        print("Tapped")
    }
}
