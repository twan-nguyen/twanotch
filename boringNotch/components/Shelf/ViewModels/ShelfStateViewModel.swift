//
//  ShelfStateViewModel.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-09.

import Foundation
import AppKit

@MainActor
final class ShelfStateViewModel: ObservableObject {
    static let shared = ShelfStateViewModel()

    @Published private(set) var items: [ShelfItem] = [] {
        didSet { ShelfPersistenceService.shared.save(items) }
    }

    @Published var isLoading: Bool = false

    var isEmpty: Bool { items.isEmpty }

    // Queue for deferred bookmark updates to avoid publishing during view updates
    private var pendingBookmarkUpdates: [ShelfItem.ID: Data] = [:]
    private var updateTask: Task<Void, Never>?
    // Resolving a bookmark touches the file system; reuse the key while an item's content is unchanged.
    private var identityKeyCache: [ShelfItem.ID: (kind: ShelfItemKind, key: String)] = [:]

    private init() {
        items = ShelfPersistenceService.shared.load()
    }


    func add(_ newItems: [ShelfItem]) {
        guard !newItems.isEmpty else { return }
        var merged = items
        var keys: [ShelfItem.ID: (kind: ShelfItemKind, key: String)] = [:]
        func identityKey(of item: ShelfItem) -> String {
            if let cached = identityKeyCache[item.id], cached.kind == item.kind {
                keys[item.id] = cached
                return cached.key
            }
            let key = item.identityKey
            keys[item.id] = (item.kind, key)
            return key
        }
        // Deduplicate by identityKey while preserving order (existing first)
        var seen: Set<String> = Set(merged.map { identityKey(of: $0) })
        for it in newItems {
            let key = it.identityKey
            if !seen.contains(key) {
                merged.append(it)
                seen.insert(key)
                keys[it.id] = (it.kind, key)
            }
        }
        identityKeyCache = keys
        items = merged
    }

    func remove(_ item: ShelfItem) {
        item.cleanupStoredData()
        items.removeAll { $0.id == item.id }
    }

    func updateBookmark(for item: ShelfItem, bookmark: Data) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if case .file = items[idx].kind {
            items[idx].kind = .file(bookmark: bookmark)
        }
    }

    private func scheduleDeferredBookmarkUpdate(for item: ShelfItem, bookmark: Data) {
        pendingBookmarkUpdates[item.id] = bookmark
        
        // Cancel existing task and schedule a new one
        updateTask?.cancel()
        updateTask = Task { @MainActor [weak self] in
            await Task.yield()
            
            guard let self = self else { return }
            
            for (itemID, bookmarkData) in self.pendingBookmarkUpdates {
                if let idx = self.items.firstIndex(where: { $0.id == itemID }),
                   case .file = self.items[idx].kind {
                    self.items[idx].kind = .file(bookmark: bookmarkData)
                }
            }
            
            self.pendingBookmarkUpdates.removeAll()
        }
    }


    func load(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        isLoading = true
        Task { [weak self] in
            let dropped = await ShelfDropService.items(from: providers)
            await MainActor.run {
                self?.add(dropped)
                self?.isLoading = false
            }
        }
    }

    func cleanupInvalidItems() {
        Task { [weak self] in
            guard let self else { return }
            var invalidIDs: Set<ShelfItem.ID> = []
            for item in self.items {
                guard case .file(let data) = item.kind else { continue }
                // Items on an unmounted volume are kept; only files that are really gone are dropped.
                if await Bookmark(data: data).validationState() == .missing {
                    invalidIDs.insert(item.id)
                }
            }
            guard !invalidIDs.isEmpty else { return }

            // `items` may have changed while validating (drops, removals), so act on the current
            // array instead of writing back the snapshot.
            for item in self.items where invalidIDs.contains(item.id) {
                item.cleanupStoredData()
            }
            self.items.removeAll { invalidIDs.contains($0.id) }
        }
    }


    func resolveFileURL(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            scheduleDeferredBookmarkUpdate(for: item, bookmark: refreshed)
        }
        return result.url
    }

    func resolveAndUpdateBookmark(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            updateBookmark(for: item, bookmark: refreshed)
        }
        return result.url
    }

    func resolveFileURLs(for items: [ShelfItem]) -> [URL] {
        var urls: [URL] = []
        for it in items {
            if let u = resolveFileURL(for: it) { urls.append(u) }
        }
        return urls
    }
}
