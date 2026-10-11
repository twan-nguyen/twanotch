//
//  Bookmark.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-08.
//

import Foundation
import AppKit

struct Bookmark: Sendable, Equatable, Codable {
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(url: URL) throws {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "Bookmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a valid file URL or file does not exist at \(url.path)"])
        }
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            NSLog("✅ Successfully created bookmark for \(url.path)")
            self.data = bookmark
        } catch {
            NSLog("❌ Failed to create bookmark for \(url.path): \(error.localizedDescription)")
            throw error
        }
    }

    /// Resolves the bookmark. Pass `mountIfNeeded: false` on display and validation paths so a
    /// bookmark on an unmounted network volume fails fast instead of trying to mount the share
    /// (which blocks the caller and can raise a login prompt). Explicit user actions may mount.
    /// `error` is set when resolution fails so callers can tell a missing file from a transient failure.
    func resolve(mountIfNeeded: Bool = true) -> (url: URL?, refreshedData: Data?, error: Error?) {
        guard !data.isEmpty else { return (nil, nil, nil) }
        var isStale = false
        var options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        if !mountIfNeeded { options.insert(.withoutMounting) }
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            // Creating a security-scoped bookmark needs active access to the resource in the sandbox.
            if isStale, let newData = url.accessSecurityScopedResource(accessor: { try? $0.bookmarkData(options: [.withSecurityScope]) }) {
                NSLog("⚠️ Bookmark was stale for \(url.path), refreshed")
                return (url, newData, nil)
            }
            return (url, nil, nil)
        } catch {
            NSLog("❌ Failed to resolve bookmark: \(error.localizedDescription)")
            return (nil, nil, error)
        }
    }

    func resolveURL() -> URL? {
        return resolve().url
    }

    var refreshedData: Data? {
        return resolve().refreshedData
    }
    
    static func update(in items: inout [ShelfItem], for item: ShelfItem, newBookmark: Data) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        guard case .file = items[idx].kind else { return }
        items[idx].kind = ShelfItemKind.file(bookmark: newBookmark)
    }

    enum ValidationState: Sendable, Equatable {
        case valid
        /// The file is gone (or the bookmark is unusable) while its volume is reachable.
        case missing
        /// The file lives on a volume that is not mounted right now, so its state is unknown.
        case volumeUnavailable
        /// Resolution failed for a reason that does not prove the file is gone (agent, permission, ...).
        case unknown
    }

    func validate() async -> Bool {
        await validationState() == .valid
    }

    func validationState() async -> ValidationState {
        guard !data.isEmpty else { return .missing }
        let result = resolve(mountIfNeeded: false)
        if let url = result.url {
            if url.accessSecurityScopedResource(accessor: { FileManager.default.fileExists(atPath: $0.path) }) {
                return .valid
            }
            return volumeIsMounted ? .missing : .volumeUnavailable
        }
        guard volumeIsMounted else { return .volumeUnavailable }
        // Only a definitive "no such file" proves the item is gone; anything else may be transient.
        if let error = result.error as NSError?,
           error.domain == NSCocoaErrorDomain,
           error.code == CocoaError.fileNoSuchFile.rawValue || error.code == CocoaError.fileReadNoSuchFile.rawValue {
            return .missing
        }
        return .unknown
    }

    /// Whether the volume recorded in the bookmark is currently mounted. Defaults to true when
    /// the volume cannot be read from the bookmark, so only a positively unmounted volume is spared.
    var volumeIsMounted: Bool {
        guard !data.isEmpty,
              let volumeURL = URL.resourceValues(forKeys: [.volumeURLKey], fromBookmarkData: data)?.volume
        else { return true }
        return FileManager.default.fileExists(atPath: volumeURL.path)
    }

    /// The file name stored in the bookmark, readable without touching the file or its volume.
    var cachedName: String? {
        guard !data.isEmpty else { return nil }
        return URL.resourceValues(forKeys: [.nameKey], fromBookmarkData: data)?.name
    }

    func withAccess<T: Sendable>(_ block: @Sendable (URL) async throws -> T) async rethrows -> T? {
        let url = resolveURL()
        guard let url = url else { return nil }
        return try await url.accessSecurityScopedResource { url in
            try await block(url)
        }
    }

    func withAccess<T>(_ block: (URL) throws -> T) rethrows -> T? {
        let url = resolveURL()
        guard let url = url else { return nil }
        return try url.accessSecurityScopedResource { url in
            try block(url)
        }
    }
}
