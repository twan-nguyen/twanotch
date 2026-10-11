//
//  QuickShareService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

/// Dynamic representation of a sharing provider discovered at runtime
struct QuickShareProvider: Identifiable, Hashable, Sendable {
    var id: String
    var imageData: Data?
    var supportsRawText: Bool
}

class QuickShareService: ObservableObject {
    static let shared = QuickShareService()
    
    @Published var availableProviders: [QuickShareProvider] = []
    @Published var isPickerOpen = false
    // Used for the provider list and as a first candidate; a service has a single delegate, so one
    // that is still driving another session is never reused (see `availableService`).
    private var cachedServices: [String: NSSharingService] = [:]
   
    init() {
        Task {
            await discoverAvailableProviders()
        }
    }
    
    // MARK: - Provider Discovery
    
    @MainActor
    func discoverAvailableProviders() async {
        let finder = ShareServiceFinder()

        // Use simple test items without creating actual temp files
        // This avoids issues with the Share Sheet retaining references to deleted files
        let testItems: [Any] = [
            URL(string:"http://example.com") ?? URL(fileURLWithPath: "/"),
            "Test Text" as NSString
        ]

        let services = await finder.findApplicableServices(for: testItems)

        var providers: [QuickShareProvider] = []

        for svc in services {
            let title = svc.title
            let imgData = svc.image.tiffRepresentation
            let supportsRawText = svc.canPerform(withItems: ["Test Text"])
            let provider = QuickShareProvider(id: title, imageData: imgData, supportsRawText: supportsRawText)
            if !providers.contains(provider) {
                providers.append(provider)
                cachedServices[title] = svc
            }
        }
        
        if let idx = providers.firstIndex(where: { $0.id == "AirDrop" }) {
            let ad = providers.remove(at: idx)
            providers.insert(ad, at: 0)
        }

        if !providers.contains(where: { $0.id == "System Share Menu" }) {
            providers.append(QuickShareProvider(id: "System Share Menu", imageData: nil, supportsRawText: true))
        }

        self.availableProviders = providers

    }
    
    // MARK: - File Picker
    @MainActor
    func showFilePicker(for provider: QuickShareProvider, from view: NSView?) async {
        guard !isPickerOpen else {
            print("⚠️ QuickShareService: File picker already open")
            return
        }

        isPickerOpen = true
        SharingStateManager.shared.beginInteraction()

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.title = "Select Files for \(provider.id)"
        panel.message = "Choose files to share via \(provider.id)"

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            defer {
                self?.isPickerOpen = false
                SharingStateManager.shared.endInteraction()
            }

            if response == .OK && !panel.urls.isEmpty {
                Task {
                    await self?.shareFilesOrText(panel.urls, using: provider, from: view)
                }
            }
        }

        let response = panel.runModal()
        completion(response)
    }
    
    // MARK: - Sharing
    /// - Parameter onEnd: Runs once the sharing session has ended (service finished, failed or the
    ///   picker was dismissed), i.e. when the shared items are no longer needed.
    @MainActor
    func shareFilesOrText(_ items: [Any], using provider: QuickShareProvider, from view: NSView?, onEnd: (() -> Void)? = nil) async {
        let fileURLs = items.compactMap { $0 as? URL }.filter { $0.isFileURL }

        let directService = await availableService(for: provider, items: items)
        // Without a service or a view in a window to anchor the picker nothing is presented (the notch
        // may have closed while items were loading), so no delegate callback would ever report the end.
        // Bail out before the session starts.
        guard directService != nil || view?.window != nil else {
            onEnd?()
            return
        }

        // Start security-scoped access for all file URLs. The session owns exactly the URLs it started,
        // so a newer session can never stop access an older one still needs (and vice versa).
        let accessedURLs = fileURLs.filter { $0.startAccessingSecurityScopedResource() }

        // Setup lifecycle delegate to keep notch open during picker/service
        let delegate = SharingStateManager.shared.makeDelegate {
            NSLog("Stopping sharing access to URLs")
            for url in accessedURLs {
                url.stopAccessingSecurityScopedResource()
            }
            onEnd?()
        }

        if let svc = directService {
            // For direct service path, explicitly mark service interaction start
            delegate.markServiceBegan()
            svc.delegate = delegate
            svc.perform(withItems: items)
        } else if let view, view.window != nil {
            let picker = NSSharingServicePicker(items: items)
            picker.delegate = delegate
            delegate.markPickerBegan()
            picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
    }

// MARK: - SharingServiceDelegate

    /// Returns a service that can perform `items` and is not already delegated to another session,
    /// so a new session can never take over (and cut short) a running one. Falls back to nil, which
    /// makes the caller use a picker with its own services.
    @MainActor
    private func availableService(for provider: QuickShareProvider, items: [Any]) async -> NSSharingService? {
        guard let cached = cachedServices[provider.id], cached.canPerform(withItems: items) else { return nil }
        if cached.delegate == nil { return cached }
        let fresh = await ShareServiceFinder().findApplicableServices(for: items)
        return fresh.first { $0.title == provider.id && $0.delegate == nil && $0.canPerform(withItems: items) }
    }

private class SharingServiceDelegate: NSObject {}
    
    func shareDroppedFiles(_ providers: [NSItemProvider], using shareProvider: QuickShareProvider, from view: NSView?) async {
        var itemsToShare: [Any] = []
        var foundText: String?

        for provider in providers {
            if let webURL = await provider.extractURL() {
                itemsToShare.append(webURL)
            } else if foundText == nil, let text = await provider.extractText() {
                foundText = text
            } else if let itemFileURL = await provider.extractItem() {
                let resolvedURL = await resolveShelfItemBookmark(for: itemFileURL) ?? itemFileURL
                itemsToShare.append(resolvedURL)
            }
        }

        // If text was found, prioritize sharing it.
        if let text = foundText {
            if shareProvider.supportsRawText {
                await shareFilesOrText([text], using: shareProvider, from: view)
            } else {
                if let tempTextURL = await TemporaryFileStorageService.shared.createTempFile(for: .text(text)) {
                    // The share service reads the file after this call returns, so delete it
                    // only when the sharing session ends.
                    await shareFilesOrText([tempTextURL], using: shareProvider, from: view) {
                        TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: tempTextURL)
                    }
                } else {
                    await shareFilesOrText([text], using: shareProvider, from: view)
                }
            }
        } else if !itemsToShare.isEmpty {
            await shareFilesOrText(itemsToShare, using: shareProvider, from: view)
        }
    }

    private func resolveShelfItemBookmark(for fileURL: URL) async -> URL? {
        let items = await ShelfStateViewModel.shared.items

        for itm in items {
            // Only matching paths here: avoid mounting shares or rewriting bookmarks of unrelated items.
            if let resolved = await ShelfStateViewModel.shared.resolveFileURL(for: itm) {
                if resolved.standardizedFileURL.path == fileURL.standardizedFileURL.path {
                    return resolved
                }
            }
        }
        print("❌ Failed to resolve bookmark for shelf item")
        return nil
    }
}

// MARK: - App Storage Extension for Provider Selection

extension QuickShareProvider {
    static var defaultProvider: QuickShareProvider {
        let svc = QuickShareService.shared

        if let airdrop = svc.availableProviders.first(where: { $0.id == "AirDrop" }) {
            return airdrop
        }
        return svc.availableProviders.first ?? QuickShareProvider(id: "System Share Menu", imageData: nil, supportsRawText: true)
    }
}
