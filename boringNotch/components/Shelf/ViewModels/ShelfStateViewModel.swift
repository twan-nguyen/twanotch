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

    // A stale bookmark is persisted at most once per item per session, so a bookmark that
    // resolves as stale every time cannot rewrite the items file in a loop.
    private var refreshedBookmarkIDs: Set<ShelfItem.ID> = []
    // Resolving a bookmark touches the file system; reuse the key while an item's content is unchanged.
    private var identityKeyCache: [ShelfItem.ID: (kind: ShelfItemKind, key: String)] = [:]

    private init() {
        items = ShelfPersistenceService.shared.load()
        // Only a fully decoded items file proves which stored files are still referenced.
        if ShelfPersistenceService.shared.loadedCleanly {
            removeOrphanedStoredFiles()
        }
    }

    /// Deletes stored shelf files that no remaining item points to (e.g. files whose deletion was
    /// deferred after being dragged out). Gives up if any item cannot be resolved, because its
    /// file might be one of the candidates.
    private func removeOrphanedStoredFiles() {
        var referenced: [URL] = []
        for item in items {
            guard case .file(let data) = item.kind else { continue }
            let bookmark = Bookmark(data: data)
            if let url = bookmark.resolve(mountIfNeeded: false).url {
                referenced.append(url)
            } else if bookmark.volumeIsMounted {
                NSLog("Skipping shelf orphan cleanup: an item could not be resolved")
                return
            }
        }
        TemporaryFileStorageService.shared.removeOrphanedShelfFiles(keeping: referenced)
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

    /// - Parameter deleteStoredFile: Pass false to keep a temporary item's stored file on disk, for
    ///   when another app may still be reading it (e.g. right after a drag); orphan cleanup removes it later.
    func remove(_ item: ShelfItem, deleteStoredFile: Bool = true) {
        invalidateThumbnail(for: item)
        if deleteStoredFile {
            item.cleanupStoredData()
        }
        items.removeAll { $0.id == item.id }
        refreshedBookmarkIDs.remove(item.id)
    }

    private func invalidateThumbnail(for item: ShelfItem) {
        guard let url = item.fileURL else { return }
        Task { await ThumbnailService.shared.clearCache(for: url) }
    }

    func updateBookmark(for item: ShelfItem, bookmark: Data) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if case .file = items[idx].kind {
            items[idx].kind = .file(bookmark: bookmark)
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
                self.invalidateThumbnail(for: item)
                item.cleanupStoredData()
            }
            self.items.removeAll { invalidIDs.contains($0.id) }
        }
    }


    /// Read-only resolution for getters and display: never mounts a volume and never writes state,
    /// so it is safe to call while views render.
    func resolveFileURL(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        return Bookmark(data: bookmarkData).resolve(mountIfNeeded: false).url
    }

    /// Resolution for user-initiated actions (drag, share, copy): may mount a volume and persists a
    /// refreshed bookmark, at most once per item per session.
    func resolveAndUpdateBookmark(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData,
           refreshedBookmarkIDs.insert(item.id).inserted {
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
