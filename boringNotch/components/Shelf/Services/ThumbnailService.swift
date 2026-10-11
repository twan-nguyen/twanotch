//
//  ThumbnailService.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-07.
//

import Foundation
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

actor ThumbnailService {
    static let shared = ThumbnailService()

    private static let maxCachedThumbnails = 200

    private var cache: [String: NSImage] = [:]
    // Insertion order of `cache` keys, used to evict the oldest entries once the cache is full.
    private var cacheOrder: [String] = []
    private var pendingRequests: [String: Task<NSImage?, Never>] = [:]
    private let thumbnailGenerator = QLThumbnailGenerator.shared

    private init() {}
    
    func thumbnail(for url: URL, size: CGSize) async -> NSImage? {
        let cacheKey = "\(url.path)_\(size.width)x\(size.height)"
        
        if let cached = cache[cacheKey] {
            return cached
        }
        
        if let pending = pendingRequests[cacheKey] {
            return await pending.value
        }
        
        let task = Task<NSImage?, Never> {
            let thumbnail = await generateQuickLookThumbnail(for: url, size: size)
            if let thumbnail = thumbnail {
                store(thumbnail, forKey: cacheKey)
            }
            pendingRequests[cacheKey] = nil
            return thumbnail
        }
        
        pendingRequests[cacheKey] = task
        return await task.value
    }
    
    func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }
    
    func clearCache(for url: URL) {
        // Keys are "<path>_<w>x<h>"; match the exact path or a descendant, not a sibling sharing the prefix.
        let path = url.path
        cache = cache.filter { key, _ in
            guard let sizeSeparator = key.lastIndex(of: "_") else { return true }
            let keyPath = key[..<sizeSeparator]
            return keyPath != path && !keyPath.hasPrefix(path + "/")
        }
        cacheOrder.removeAll { cache[$0] == nil }
    }

    private func store(_ thumbnail: NSImage, forKey key: String) {
        if cache.updateValue(thumbnail, forKey: key) == nil {
            cacheOrder.append(key)
        }
        while cacheOrder.count > Self.maxCachedThumbnails {
            cache[cacheOrder.removeFirst()] = nil
        }
    }
    
    // MARK: - Private Methods
    
    private func generateQuickLookThumbnail(for url: URL, size: CGSize) async -> NSImage? {
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
        
        return await url.accessSecurityScopedResource { scopedURL in
            NSLog("🔐 ThumbnailService: obtaining security scope for \(scopedURL.path)")
            let request = QLThumbnailGenerator.Request(
                fileAt: scopedURL,
                size: size,
                scale: scale,
                representationTypes: .all
            )
            request.iconMode = true

            return await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
                thumbnailGenerator.generateBestRepresentation(for: request) { representation, error in
                    if let rep = representation {
                        NSLog("🔍 ThumbnailService: generated thumbnail for \(scopedURL.path)")
                        continuation.resume(returning: rep.nsImage)
                    } else {
                        if let err = error { 
                            NSLog("⚠️ ThumbnailService: thumbnail error for \(scopedURL.path): \(err.localizedDescription)") 
                        }
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
}

// MARK: - Extensions

extension QLThumbnailRepresentation {
    var nsImage: NSImage {
        return NSImage(cgImage: self.cgImage, size: self.cgImage.size)
    }
}

extension CGImage {
    var size: NSSize {
        return NSSize(width: self.width, height: self.height)
    }
}
