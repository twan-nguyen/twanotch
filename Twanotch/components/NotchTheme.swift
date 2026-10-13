//
//  NotchTheme.swift
//  Twanotch
//
//  Shared colors, corner radii and spacing for everything drawn inside the open notch, so cards,
//  controls and panels from different tabs read as one system.
//

import SwiftUI

enum NotchTheme {
    /// Fills layered on the notch's black background, from faintest to strongest.
    enum Fill {
        /// Cards and content panels.
        static let card = Color.white.opacity(0.07)
        /// Progress tracks and small pills.
        static let track = Color.white.opacity(0.1)
        /// Buttons and other controls at rest.
        static let control = Color.white.opacity(0.12)
        /// Controls under the pointer.
        static let hover = Color.white.opacity(0.18)
        /// A chosen option.
        static let selected = Color.white.opacity(0.22)
    }

    enum Radius {
        /// Buttons, options and small tiles.
        static let control: CGFloat = 10
        /// Cards and item thumbnails.
        static let card: CGFloat = 12
        /// Large drop panels.
        static let panel: CGFloat = 16
    }

    enum Spacing {
        static let tight: CGFloat = 4
        static let item: CGFloat = 8
        static let section: CGFloat = 10
    }

    static let primaryText = Color.white
    static let secondaryText = Color.gray
    static let warning = Color.orange
    static let critical = Color.red
}

/// A card that can take dropped files: a quiet outline at rest, the accent color while a drag
/// is over it.
struct NotchDropTargetBackground: View {
    var cornerRadius: CGFloat = NotchTheme.Radius.card
    let isTargeted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(isTargeted ? Color.effectiveAccent.opacity(0.14) : NotchTheme.Fill.card)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        isTargeted ? Color.effectiveAccent : NotchTheme.Fill.control,
                        style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [6, 5]))
            }
            .animation(.smooth(duration: 0.2), value: isTargeted)
    }
}

/// An icon on a round tinted badge, as used by the shelf's drop targets; the accent color by default.
struct NotchIconBadge<Icon: View>: View {
    var size: CGFloat = 48
    var tint: Color = .effectiveAccent
    let isTargeted: Bool
    @ViewBuilder let icon: Icon

    var body: some View {
        Circle()
            .fill(tint.opacity(isTargeted ? 0.35 : 0.2))
            .frame(width: size, height: size)
            .overlay { icon.foregroundStyle(tint) }
            .scaleEffect(isTargeted ? 1.06 : 1)
            .animation(.spring(response: 0.36, dampingFraction: 0.7), value: isTargeted)
    }
}

/// A round icon button for the notch header, with the same hover feedback as other controls.
struct NotchIconButton: View {
    let systemName: String
    let help: LocalizedStringKey
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .imageScale(.medium)
                .foregroundStyle(NotchTheme.primaryText)
                .frame(width: 30, height: 30)
                .background(Circle().fill(isHovering ? NotchTheme.Fill.hover : NotchTheme.Fill.control))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}
