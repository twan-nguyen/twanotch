//
//  TemporaryFileStorageService.swift
//  Twanotch
//
//  Created by Alexander on 2025-09-24.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

enum TempFileType {
    case data(Data, suggestedName: String?)
    case text(String)
    case url(URL)
}

class TemporaryFileStorageService {
    static let shared = TemporaryFileStorageService()
    
    // MARK: - Public Interface
    
    /// Creates a temporary file and tracks it for manual cleanup
    func createTempFile(for type: TempFileType) async -> URL? {
        return await withCheckedContinuation { continuation in
            let result = createTempFile(for: type)
            continuation.resume(returning: result)
        }
    }
    
    func removeTemporaryFileIfNeeded(at url: URL) {
        guard isManagedFile(url) else {
            print("Attempted to remove temporary file outside managed directories: \(url.path)")
            return
        }

        let folderURL = url.deletingLastPathComponent()

        do {
            try FileManager.default.removeItem(at: url)
            print("Deleted file: \(url.path)")

            // Never remove the storage roots themselves, only the per-file folders inside them.
            guard !isStorageRoot(folderURL) else { return }

            let contents = try FileManager.default.contentsOfDirectory(atPath: folderURL.path)
            if contents.isEmpty {
                try FileManager.default.removeItem(at: folderURL)
                print("Folder was empty, deleted folder: \(folderURL.path)")
            } else {
                print("Folder not deleted — it still contains \(contents.count) item(s).")
            }

        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }
    
    /// Deletes the per-file folders (`ShelfFiles/<uuid>`) that none of `referencedURLs` lives in.
    /// Only direct UUID-named subfolders of the ShelfFiles root are ever touched.
    func removeOrphanedShelfFiles(keeping referencedURLs: [URL]) {
        let fm = FileManager.default
        let root = shelfFilesDirectory
        let rootPath = root.resolvingSymlinksInPath().path

        var referencedFolders = Set<String>()
        for url in referencedURLs {
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(rootPath + "/") else { continue }
            if let folder = path.dropFirst(rootPath.count + 1).split(separator: "/").first {
                referencedFolders.insert(String(folder))
            }
        }

        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return }

        for entry in entries {
            let name = entry.lastPathComponent
            guard UUID(uuidString: name) != nil, !referencedFolders.contains(name) else { continue }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            do {
                try fm.removeItem(at: entry)
                print("Removed orphaned shelf folder: \(entry.path)")
            } catch {
                print("Failed to remove orphaned shelf folder \(entry.path): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Storage locations

    /// Files the user keeps on the shelf (generated files, data drops). They are persisted by
    /// bookmark, so they must live outside the system temporary directory, which macOS purges.
    private var shelfFilesDirectory: URL {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        // Same folder as the saved shelf, which keeps its boring.notch name for earlier versions.
        return support
            .appendingPathComponent("boringNotch", isDirectory: true)
            .appendingPathComponent("ShelfFiles", isDirectory: true)
    }

    /// Short-lived files that are only needed while a share session runs.
    private var shareTempDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
    }

    private func isStorageRoot(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        return [shelfFilesDirectory, shareTempDirectory].contains { $0.resolvingSymlinksInPath().path == path }
    }

    private func isManagedFile(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        return [shelfFilesDirectory, shareTempDirectory].contains {
            path.hasPrefix($0.resolvingSymlinksInPath().path + "/")
        }
    }

    /// Reduces an externally supplied name to one safe path component, or nil when nothing usable remains.
    private func sanitizedFilename(_ name: String?) -> String? {
        guard let name else { return nil }
        let component = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !component.isEmpty, component != ".", component != ".." else { return nil }
        return component
    }

    // MARK: - Private Implementation
    
    private func createTempFile(for type: TempFileType) -> URL? {
        let uuid = UUID().uuidString
        
        switch type {
        case .data(let data, let suggestedName):
            let filename = sanitizedFilename(suggestedName) ?? "\(uuid).dat"
            let dirURL = shelfFilesDirectory.appendingPathComponent(uuid, isDirectory: true)
            let fileURL = dirURL.appendingPathComponent(filename)
            
            do {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                try data.write(to: fileURL)
                return fileURL
            } catch {
                print("Error: \(error)")
                try? FileManager.default.removeItem(at: dirURL)
                return nil
            }
            
        case .text(let string):
            // Only handed to a share service, which is done with it when the session ends.
            let filename = "\(uuid).txt"
            let dirURL = shareTempDirectory.appendingPathComponent(uuid, isDirectory: true)
            let fileURL = dirURL.appendingPathComponent(filename)
            
            guard let data = string.data(using: .utf8) else {
                print("❌ Failed to convert text to data")
                return nil
            }
            
            do {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                try data.write(to: fileURL)
                return fileURL
            } catch {
                print("Error: \(error)")
                try? FileManager.default.removeItem(at: dirURL)
                return nil
            }
            
        case .url(let url):
            let filename = "\(sanitizedFilename(url.host) ?? uuid).webloc"
            let dirURL = shelfFilesDirectory.appendingPathComponent(uuid, isDirectory: true)
            let fileURL = dirURL.appendingPathComponent(filename)
            
            let weblocContent = createWeblocContent(for: url)
            guard let data = weblocContent.data(using: String.Encoding.utf8) else {
                print("❌ Failed to create webloc data")
                return nil
            }
            
            do {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                try data.write(to: fileURL)
                return fileURL
            } catch {
                print("Error: \(error)")
                try? FileManager.default.removeItem(at: dirURL)
                return nil
            }
        }
    }
    
    private func createFile(at url: URL, data: Data) -> URL? {
        do {
            try data.write(to: url)
            return url
        } catch {
            print("❌ Failed to create temp file at \(url.path): \(error)")
            return nil
        }
    }
    enum ZipError: LocalizedError {
        case nothingToArchive
        case copyFailed(path: String, underlying: Error)
        case zipFailed(status: Int32)

        var errorDescription: String? {
            switch self {
            case .nothingToArchive:
                return "No files to archive"
            case .copyFailed(let path, let underlying):
                return "Failed to copy \(path) for archiving: \(underlying.localizedDescription)"
            case .zipFailed(let status):
                return "zip exited with status \(status)"
            }
        }
    }

    func createZip(from urls: [URL], suggestedName: String? = nil) async throws -> URL {
        guard !urls.isEmpty else { throw ZipError.nothingToArchive }

        let fm = FileManager.default
        let workingDir = shelfFilesDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: workingDir, withIntermediateDirectories: true)

        // Remove the working directory (and any copies of user files in it) unless the archive was produced.
        var finished = false
        defer {
            if !finished { try? fm.removeItem(at: workingDir) }
        }

        // Helper to run zip process
        func runZip(arguments: [String], currentDirectory: URL) throws {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            proc.arguments = arguments
            proc.currentDirectoryURL = currentDirectory
            // zip must never wait on our stdin (e.g. for a "-@" argument).
            proc.standardInput = FileHandle.nullDevice
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { throw ZipError.zipFailed(status: proc.terminationStatus) }
        }

        // The archive is written under a unique name and renamed at the end, so it can never
        // collide with an archived item that happens to be called like the final archive.
        let archiveURL = workingDir.appendingPathComponent("\(UUID().uuidString).zip")
        let finalName: String

        if urls.count == 1, let src = urls.first {
            // Single-item optimization: do not copy contents into the working dir.
            let isDir = (try? src.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let baseName = src.lastPathComponent
            finalName = "\(baseName).zip"
            // Run zip from the parent directory so the item is stored without parent folders.
            // Folder: -r keeps the folder itself as top-level entry. File: -j stores only the file.
            // "--" keeps a file name such as "-@" from being parsed as an option.
            let args = [isDir ? "-r" : "-j", "-q", archiveURL.path, "--", baseName]
            try runZip(arguments: args, currentDirectory: src.deletingLastPathComponent())
        } else {
            // Multi-item: copy items into a content dir (so their relative structure is preserved), zip, then remove copies.
            let contentDir = workingDir.appendingPathComponent("content", isDirectory: true)
            try fm.createDirectory(at: contentDir, withIntermediateDirectories: true)

            for src in urls {
                var dest = contentDir.appendingPathComponent(src.lastPathComponent)
                if fm.fileExists(atPath: dest.path) {
                    // Avoid collision by prefixing a unique id
                    dest = contentDir.appendingPathComponent("\(UUID().uuidString)_\(src.lastPathComponent)")
                }
                do {
                    try fm.copyItem(at: src, to: dest)
                } catch {
                    throw ZipError.copyFailed(path: src.path, underlying: error)
                }
            }

            try runZip(arguments: ["-r", "-q", archiveURL.path, "--", "."], currentDirectory: contentDir)

            // Remove the copied (uncompressed) items so the folder contains only the archive
            do {
                try fm.removeItem(at: contentDir)
            } catch {
                print("⚠️ Failed to cleanup working directory after zip: \(error)")
            }
            finalName = sanitizedFilename(suggestedName) ?? "Archive.zip"
        }

        let finalURL = workingDir.appendingPathComponent(finalName)
        try fm.moveItem(at: archiveURL, to: finalURL)
        finished = true
        return finalURL
    }
    
    // MARK: - Content Creation Helpers
    
    
    private func createWeblocContent(for url: URL) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>URL</key>
            <string>\(url.absoluteString)</string>
        </dict>
        </plist>
        """
    }
}
