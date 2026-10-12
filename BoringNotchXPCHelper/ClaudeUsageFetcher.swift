//
//  ClaudeUsageFetcher.swift
//  BoringNotchXPCHelper
//
//  Reads the plan usage that Claude Code's `/usage` shows, using the OAuth token Claude Code keeps
//  in the login keychain. The approach follows the Claude provider of CodexBar (MIT,
//  github.com/steipete/CodexBar). The token never leaves this process: the reply carries only
//  the usage payload. This process never refreshes the token itself, because a refresh rotates the
//  refresh token and would sign Claude Code out; when it has expired, it starts Claude Code briefly
//  so Claude Code refreshes its own sign-in.
//

import Foundation

enum ClaudeUsageFetcher {
    private static let keychainService = "Claude Code-credentials"
    private static let securityPath = "/usr/bin/security"
    // Long enough to answer a keychain prompt if the item's access list ever stops trusting `security`.
    private static let securityTimeout: TimeInterval = 30
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let betaHeader = "oauth-2025-04-20"
    /// `security` exits with this status when the keychain item does not exist.
    private static let itemNotFoundStatus: Int32 = 44

    /// How long Claude Code may run to refresh its sign-in, and how often that may happen.
    private static let refreshTimeout: TimeInterval = 20
    private static let refreshCooldown: TimeInterval = 30 * 60
    private static let refreshLock = NSLock()
    private static var lastRefreshAttempt: Date?

    /// Returns a JSON object: `status` is one of ok, notSignedIn, expired, unauthorized,
    /// rateLimited or failed; `usage` holds the API response when the status is ok.
    static func fetch() async -> Data {
        let envelope = await makeEnvelope()
        return (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
    }

    private static func makeEnvelope() async -> [String: Any] {
        var credentials: Credentials
        switch readCredentials() {
        case .success(let value):
            credentials = value
        case .failure(let failure):
            return failure.envelope
        }

        if credentials.isExpired, let refreshed = refreshThroughClaudeCode() {
            credentials = refreshed
        }

        var envelope: [String: Any] = [:]
        if let plan = credentials.planName {
            envelope["plan"] = plan
        }
        if credentials.isExpired {
            envelope["status"] = "expired"
            return envelope
        }

        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: HTTPURLResponse
        do {
            let (body, urlResponse) = try await URLSession.shared.data(for: request)
            guard let http = urlResponse as? HTTPURLResponse else {
                envelope["status"] = "failed"
                return envelope
            }
            data = body
            response = http
        } catch {
            envelope["status"] = "failed"
            envelope["message"] = error.localizedDescription
            return envelope
        }

        switch response.statusCode {
        case 200:
            guard let usage = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                envelope["status"] = "failed"
                envelope["message"] = "Unexpected usage response"
                return envelope
            }
            envelope["status"] = "ok"
            envelope["usage"] = usage
        case 401:
            envelope["status"] = "unauthorized"
        case 429:
            envelope["status"] = "rateLimited"
            if let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) {
                envelope["retryAfter"] = retryAfter
            }
        default:
            envelope["status"] = "failed"
            envelope["message"] = "HTTP \(response.statusCode)"
        }
        return envelope
    }

    private static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Twanotch/\(version)"
    }

    // MARK: - Credentials

    private struct Credentials {
        let accessToken: String
        let expiresAt: Date?
        let subscriptionType: String?
        let rateLimitTier: String?

        /// Treats a token about to expire as expired, so a request never races its expiry.
        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt <= Date().addingTimeInterval(60)
        }

        /// "Max 20x", "Max 5x", "Pro"…; the tier carries the Max multiplier when there is one.
        var planName: String? {
            if let tier = rateLimitTier?.lowercased(), tier.contains("max") {
                if tier.hasSuffix("20x") { return "Max 20x" }
                if tier.hasSuffix("5x") { return "Max 5x" }
            }
            guard let type = subscriptionType?.trimmingCharacters(in: .whitespaces), !type.isEmpty else {
                return nil
            }
            return type.prefix(1).uppercased() + type.dropFirst()
        }
    }

    private enum CredentialFailure: Error {
        case notSignedIn
        case failed(String)

        var envelope: [String: Any] {
            switch self {
            case .notSignedIn:
                return ["status": "notSignedIn"]
            case .failed(let message):
                return ["status": "failed", "message": message]
            }
        }
    }

    /// Reads through `/usr/bin/security`: Claude Code writes its keychain item with that tool, so the
    /// item's access list already trusts it and reading does not ask for keychain access.
    private static func readCredentials() -> Result<Credentials, CredentialFailure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityPath)
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .failure(.failed("Could not run security"))
        }

        // Read while the process runs so a full pipe can never stall it.
        var output = Data()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            output = stdout.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        if reader.wait(timeout: .now() + securityTimeout) == .timedOut {
            process.terminate()
            return .failure(.failed("Keychain read timed out"))
        }
        process.waitUntilExit()

        if process.terminationStatus == itemNotFoundStatus {
            return .failure(.notSignedIn)
        }
        guard process.terminationStatus == 0 else {
            return .failure(.failed("Keychain read failed (\(process.terminationStatus))"))
        }

        guard let root = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              !accessToken.isEmpty
        else {
            return .failure(.notSignedIn)
        }

        let expiresAt = (oauth["expiresAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue / 1000)
        }
        return .success(Credentials(
            accessToken: accessToken,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        ))
    }

    // MARK: - Refresh through Claude Code

    /// Starts Claude Code in a pseudo-terminal, which makes it refresh an expired sign-in at launch,
    /// waits for the keychain to hold an unexpired token, then quits it. Hooks, MCP servers and tools
    /// are turned off, and nothing is typed, so Claude Code saves no session. Returns the new
    /// credentials, or `nil` when Claude Code is not installed, is in cooldown, or did not refresh.
    private static func refreshThroughClaudeCode() -> Credentials? {
        refreshLock.lock()
        if let lastRefreshAttempt, Date().timeIntervalSince(lastRefreshAttempt) < refreshCooldown {
            refreshLock.unlock()
            return nil
        }
        lastRefreshAttempt = Date()
        refreshLock.unlock()

        guard let claudePath = locateClaude() else { return nil }

        let workingDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.twan.twanotch.claude-refresh", isDirectory: true)
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let process = Process()
        // `script` gives Claude Code the terminal it needs to start interactively.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = [
            "-q", "/dev/null", claudePath,
            "--strict-mcp-config",
            "--allowed-tools", "",
            "--settings", #"{"disableAllHooks":true,"remoteControlAtStartup":false}"#
        ]
        process.currentDirectoryURL = workingDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        // Closing the terminal hangs up Claude Code, so stopping `script` stops both.
        defer {
            if process.isRunning {
                process.terminate()
                let stopDeadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < stopDeadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        let deadline = Date().addingTimeInterval(refreshTimeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
            if case .success(let credentials) = readCredentials(), !credentials.isExpired {
                return credentials
            }
            if !process.isRunning { break }
        }
        return nil
    }

    /// The XPC service does not inherit the login shell's PATH, so look in the usual install places.
    private static func locateClaude() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
