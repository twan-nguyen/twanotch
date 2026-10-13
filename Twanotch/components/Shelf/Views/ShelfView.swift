//
//  ShelfItemView.swift
//  Twanotch
//
//  Created by Alexander on 2025-09-24.
//

import SwiftUI
import AppKit

struct ShelfView: View {
    @EnvironmentObject var vm: NotchViewModel
    @StateObject var tvm = ShelfStateViewModel.shared
    @StateObject var selection = ShelfSelectionModel.shared
    @StateObject private var quickLookService = QuickLookService()
    private let spacing: CGFloat = 8
    @State private var isHoveringPanel = false

    /// The empty shelf's icon comes alive while the pointer or a drag is over it.
    private var isEmptyPanelActive: Bool { isHoveringPanel || vm.dragDetectorTargeting }

    var body: some View {
        HStack(spacing: 12) {
            FileShareView()
                .aspectRatio(1, contentMode: .fit)
                .environmentObject(vm)
            panel
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
        }
        // Bind Quick Look to shelf selection
        .onChange(of: selection.selectedIDs) {
            updateQuickLookSelection()
        }
        .quickLookPresenter(using: quickLookService)
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !selection.isDragging else { return false }
        vm.dropEvent = true
        ShelfStateViewModel.shared.load(providers)
        return true
    }
    
    private func updateQuickLookSelection() {
        guard quickLookService.isQuickLookOpen && !selection.selectedIDs.isEmpty else { return }
        
        let selectedItems = selection.selectedItems(in: tvm.items)
        let urls: [URL] = selectedItems.compactMap { item in
            if let fileURL = item.fileURL {
                return fileURL
            }
            if case .link(let url) = item.kind {
                return url
            }
            return nil
        }
        
        if !urls.isEmpty {
            quickLookService.updateSelection(urls: urls)
        }
    }

    var panel: some View {
        NotchDropTargetBackground(cornerRadius: NotchTheme.Radius.panel, isTargeted: vm.dragDetectorTargeting)
            .overlay {
                content
                    .padding()
            }
            .transaction { transaction in
                transaction.animation = vm.animation
            }
            .contentShape(Rectangle())
            .onTapGesture { selection.clear() }
            .onHover { isHoveringPanel = $0 }
    }

    var content: some View {
        Group {
            if tvm.isEmpty {
                VStack(spacing: NotchTheme.Spacing.section) {
                    NotchIconBadge(isTargeted: isEmptyPanelActive) {
                        ShelfTrayIcon(isAnimating: isEmptyPanelActive)
                    }

                    Text("Drop files here")
                        .foregroundStyle(vm.dragDetectorTargeting ? NotchTheme.primaryText : NotchTheme.secondaryText)
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.medium)
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: spacing) {
                        ForEach(tvm.items) { item in
                            ShelfItemView(item: item)
                                .environmentObject(quickLookService)
                        }
                    }
                }
                .padding(-spacing)
                .scrollIndicators(.never)
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
            }
        }
        .onAppear {
            ShelfStateViewModel.shared.cleanupInvalidItems()
        }
    }
}

/// The empty shelf's tray, its arrow dropping in about once a second while `isAnimating`;
/// still with Reduce Motion.
private struct ShelfTrayIcon: View {
    var isAnimating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounces = 0

    var body: some View {
        Image(systemName: "tray.and.arrow.down.fill")
            .font(.system(size: 20, weight: .semibold))
            .symbolEffect(.bounce.down, value: bounces)
            .task(id: isAnimating && !reduceMotion) {
                guard isAnimating && !reduceMotion else { return }
                while !Task.isCancelled {
                    bounces += 1
                    try? await Task.sleep(for: .seconds(1.1))
                }
            }
    }
}
