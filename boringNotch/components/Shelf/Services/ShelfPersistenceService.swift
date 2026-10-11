//
//  ShelfPersistenceService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import Foundation

// Access model types
@_exported import struct Foundation.URL


final class ShelfPersistenceService {
    static let shared = ShelfPersistenceService()

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var savingDisabled = false
    private var loggedSavingDisabled = false
    /// True only when the last `load()` decoded every stored item without needing a quarantine.
    private(set) var loadedCleanly = false

    private init() {
        let fm = FileManager.default
        let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = (support ?? fm.temporaryDirectory).appendingPathComponent("boringNotch", isDirectory: true).appendingPathComponent("Shelf", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("items.json")
        encoder.outputFormatting = [.prettyPrinted]
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    func load() -> [ShelfItem] {
        loadedCleanly = false
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            print("❌ Failed to read shelf persistence file: \(error.localizedDescription)")
            quarantineCorruptFile(keepOriginal: false)
            return []
        }
        
        // Try to decode as array first (normal case)
        if let items = try? decoder.decode([ShelfItem].self, from: data) {
            loadedCleanly = true
            return items
        }
        
        // If array decoding fails, try to decode individual items
        do {
            // Parse as JSON array to get individual item data
            guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                print("⚠️ Shelf persistence file is not a valid JSON array")
                quarantineCorruptFile(keepOriginal: false)
                return []
            }
            
            var validItems: [ShelfItem] = []
            var failedCount = 0
            
            for (index, jsonItem) in jsonArray.enumerated() {
                do {
                    let itemData = try JSONSerialization.data(withJSONObject: jsonItem)
                    let item = try decoder.decode(ShelfItem.self, from: itemData)
                    validItems.append(item)
                } catch {
                    failedCount += 1
                    print("⚠️ Failed to decode shelf item at index \(index): \(error.localizedDescription)")
                }
            }
            
            if failedCount > 0 {
                print("📦 Successfully loaded \(validItems.count) shelf items, \(failedCount) could not be decoded")
                // The next save rewrites the file with only the valid items, so keep the undecodable ones.
                quarantineCorruptFile(keepOriginal: !validItems.isEmpty)
                // Rewrite the file with the valid items now, otherwise every launch would
                // copy the same undecodable file into a new quarantine copy.
                if !validItems.isEmpty { save(validItems) }
            }
            
            return validItems
        } catch {
            print("❌ Failed to parse shelf persistence file: \(error.localizedDescription)")
            quarantineCorruptFile(keepOriginal: false)
            return []
        }
    }

    /// Preserves a file that could not be fully read so the next save cannot destroy it.
    /// With `keepOriginal` the file is copied (it still holds the items that did load); otherwise it is moved aside.
    private func quarantineCorruptFile(keepOriginal: Bool) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let destination = fileURL.deletingLastPathComponent()
            .appendingPathComponent("items.corrupt-\(formatter.string(from: Date())).json")
        do {
            if keepOriginal {
                try FileManager.default.copyItem(at: fileURL, to: destination)
            } else {
                try FileManager.default.moveItem(at: fileURL, to: destination)
            }
            print("📦 Kept the unreadable shelf data at \(destination.path)")
        } catch {
            // Without a safe copy, any save would permanently replace the original.
            savingDisabled = true
            print("❌ Failed to preserve the unreadable shelf data, saving is disabled: \(error.localizedDescription)")
        }
    }

    func save(_ items: [ShelfItem]) {
        guard !savingDisabled else {
            if !loggedSavingDisabled {
                loggedSavingDisabled = true
                NSLog("❌ Shelf changes are not being saved: saving is disabled to protect unreadable shelf data")
            }
            return
        }
        do {
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: Data.WritingOptions.atomic)
        } catch {
            print("Failed to save shelf items: \(error.localizedDescription)")
        }
    }
}
