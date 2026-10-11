//
//  MediaChecker.swift
//  boringNotch
//
//  Created by Alexander on 2025-07-26.
//

import Foundation

final class MediaChecker: Sendable {

    enum MediaCheckerError: Error {
        case missingResources
        case processExecutionFailed
        case timeout
    }

    func checkDeprecationStatus() async throws -> Bool {
        try await Task.detached(priority: .userInitiated) {
            guard let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
                  let nowPlayingTestClientPath = Bundle.main.url(forResource: "MediaRemoteAdapterTestClient", withExtension: nil)?.path,
                  let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework")
            else {
                throw MediaCheckerError.missingResources
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [scriptURL.path, frameworkPath, nowPlayingTestClientPath, "test"]

            // Set the handler before run() so a fast exit is never missed.
            let exited = AsyncStream<Void> { continuation in
                process.terminationHandler = { _ in
                    continuation.yield()
                    continuation.finish()
                }
            }

            do {
                try process.run()
            } catch {
                throw MediaCheckerError.processExecutionFailed
            }

            // Timeout after 10 seconds
            let didExit: Bool = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await _ in exited { break }
                    return true
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    return false // Timed out
                }
                defer { group.cancelAll() }
                return try await group.next() ?? false
            }

            if !didExit {
                if process.isRunning {
                    process.terminate()
                }
                throw MediaCheckerError.timeout
            }

            let isDeprecated = process.terminationStatus == 1
            return isDeprecated
        }.value
    }
}
