//
//  FileShareView.swift
//  Twanotch
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct FileShareView: View {
    @EnvironmentObject private var vm: NotchViewModel
    @StateObject private var quickShare = QuickShareService.shared
    @Default(.quickShareProvider) var quickShareProvider: String

    @State private var hostView: NSView?
    @State private var interactionNonce: UUID = .init()
    @State private var isProcessing = false
    @State private var isHovering = false

    /// The icon comes alive while the pointer or a drag is over the tile.
    private var isActive: Bool { isHovering || vm.dropZoneTargeting }
    
    private var selectedProvider: QuickShareProvider {
        quickShare.availableProviders.first(where: { $0.id == quickShareProvider }) ?? QuickShareProvider(id: "System Share Menu", imageData: nil, supportsRawText: true)
    }

    var body: some View {
        dropArea
            .background(NSViewHost(view: $hostView))
            .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data, .image], isTargeted: $vm.dropZoneTargeting) { providers in
                interactionNonce = .init()
                ShelfSelectionModel.shared.markDragConsumedByShare()
                vm.dropEvent = true
                Task { await handleDrop(providers) }
                return true
            }
            .onTapGesture {
                Task {
                    await handleClick()
                }
            }
            .onHover { isHovering = $0 }
    }

    private var dropArea: some View {
        ZStack {
            NotchDropTargetBackground(isTargeted: vm.dropZoneTargeting)

            VStack(spacing: NotchTheme.Spacing.item) {
                if selectedProvider.id == "AirDrop" {
                    NotchIconBadge(tint: AirDropGlyph.blue, isTargeted: isActive) {
                        AirDropMark(isAnimating: isActive)
                            .frame(width: 26, height: 26)
                    }
                } else {
                    NotchIconBadge(isTargeted: isActive) {
                        if let imgData = selectedProvider.imageData, let nsImg = NSImage(data: imgData) {
                            // The service's own icon keeps its colors.
                            Image(nsImage: nsImg)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 28, height: 28)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 20, weight: .semibold))
                                .offset(y: -1)
                        }
                    }
                }

                VStack(spacing: 2) {
                    Text(selectedProvider.id)
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(NotchTheme.primaryText)
                        .lineLimit(1)
                    Text("Drop or click")
                        .font(.caption)
                        .foregroundStyle(NotchTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            .padding(NotchTheme.Spacing.section)
            
            // Loading overlay
            if isProcessing || quickShare.isPickerOpen {
                RoundedRectangle(cornerRadius: NotchTheme.Radius.card)
                    .fill(.black.opacity(0.3))
                    .overlay(
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    )
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: NotchTheme.Radius.card))
    }

    // MARK: - Actions

    private func handleDrop(_ providers: [NSItemProvider]) async {
        isProcessing = true
        defer { isProcessing = false }
        await quickShare.shareDroppedFiles(providers, using: selectedProvider, from: hostView)
    }
    
    private func handleClick() async {
        await quickShare.showFilePicker(for: selectedProvider, from: hostView)
    }
}

/// The AirDrop mark: a dot inside three waves that open towards the bottom. macOS has no public
/// SF Symbol for it, and the sharing service's own icon is too small to scale up.
struct AirDropGlyph: Shape {
    static let blue = Color(red: 0.04, green: 0.52, blue: 1.0)

    enum Part: Equatable {
        case all, dot
        /// 0 is the wave closest to the dot.
        case wave(Int)
    }

    var part: Part = .all

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let unit = side / 2 / 4.3
        var path = Path()
        if part == .all || part == .dot {
            path.addEllipse(in: CGRect(x: center.x - unit, y: center.y - unit, width: 2 * unit, height: 2 * unit))
        }
        // Each wave runs over the top, leaving a gap of 70° around the bottom.
        for (index, radius) in [2.2, 3.35, 4.5].map({ $0 * unit - unit * 0.2 }).enumerated() {
            guard part == .all || part == .wave(index) else { continue }
            var wave = Path()
            wave.addArc(center: center, radius: radius, startAngle: .degrees(125), endAngle: .degrees(55), clockwise: false)
            path.addPath(wave.strokedPath(StrokeStyle(lineWidth: unit * 0.65, lineCap: .round)))
        }
        return path
    }
}

/// The AirDrop mark, with its waves lighting up one after another, from the dot outwards,
/// while `isAnimating`; still with Reduce Motion.
struct AirDropMark: View {
    var isAnimating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let cycle: TimeInterval = 1.2

    var body: some View {
        if isAnimating && !reduceMotion {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
                ZStack {
                    AirDropGlyph(part: .dot)
                    ForEach(0..<3, id: \.self) { index in
                        AirDropGlyph(part: .wave(index))
                            .opacity(waveOpacity(index, phase: phase))
                    }
                }
            }
        } else {
            AirDropGlyph()
        }
    }

    /// A bright band moves outwards; each wave peaks a quarter of the cycle after the one inside it.
    private func waveOpacity(_ index: Int, phase: Double) -> Double {
        let distance = abs(phase - Double(index + 1) / 4)
        return 0.3 + 0.7 * max(0, 1 - distance * 4)
    }
}

// MARK: - Host NSView extractor for anchoring share sheet

private struct NSViewHost: NSViewRepresentable {
    @Binding var view: NSView?
    
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { self.view = v }
        return v
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { self.view = nsView }
    }
}
