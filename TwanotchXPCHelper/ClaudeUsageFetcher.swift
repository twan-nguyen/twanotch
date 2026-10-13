//
//  ClaudeUsageFetcher.swift
//  TwanotchXPCHelper
//
//  Reads Claude plan usage by asking Claude Code itself, like the CLI source of CodexBar (MIT,
//  github.com/steipete/CodexBar): `claude auth status` for the sign-in and plan, and
//  `claude -p /usage` for the limits. Twanotch never reads Claude Code's token and makes no
//  network request of its own; Claude Code also refreshes its own sign-in when it needs to.
//  The sandboxed app cannot start Claude Code, so the helper does.
//

import Foundation

enum ClaudeUsageFetcher {
    private static let usageTimeout: TimeInterval = 45
    private static let statusTimeout: TimeInterval = 15

    /// Returns a JSON object: `status` is ok, notInstalled, notSignedIn or failed; `output` holds the
    /// text `/usage` printed when the status is ok, and `plan` the subscription when known.
    static func fetch() async -> Data {
        let envelope = makeEnvelope()
        return (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
    }

    private static func makeEnvelope() -> [String: Any] {
        guard let claude = locateClaude() else { return ["status": "notInstalled"] }

        var envelope: [String: Any] = [:]
        // `auth status` answers from local state, so a signed-out Claude Code is caught without more work.
        if let status = run(claude, ["auth", "status"], timeout: statusTimeout),
           let auth = try? JSONSerialization.jsonObject(with: Data(status.output.utf8)) as? [String: Any]
        {
            if auth["loggedIn"] as? Bool == false {
                return ["status": "notSignedIn"]
            }
            if let plan = (auth["subscriptionType"] as? String)?.trimmingCharacters(in: .whitespaces), !plan.isEmpty {
                envelope["plan"] = plan.prefix(1).uppercased() + plan.dropFirst()
            }
        }

        // No session is saved, and hooks, MCP servers and tools are off, so this leaves nothing behind.
        let arguments = [
            "-p", "/usage",
            "--no-session-persistence",
            "--strict-mcp-config",
            "--allowed-tools", "",
            "--settings", #"{"disableAllHooks":true}"#,
        ]
        guard let usage = run(claude, arguments, timeout: usageTimeout) else {
            envelope["status"] = "failed"
            envelope["message"] = "Claude Code did not answer"
            return envelope
        }
        guard usage.status == 0 else {
            envelope["status"] = "failed"
            envelope["message"] = usage.output.split(separator: "\n").first.map(String.init) ?? "Claude Code failed"
            return envelope
        }
        envelope["status"] = "ok"
        envelope["output"] = usage.output
        return envelope
    }

    /// Runs Claude Code in Twanotch's own working folder and returns its output, or nil on timeout.
    private static func run(_ claude: String, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String)? {
        let workingDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.twan.twanotch.claude-usage", isDirectory: true)
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = stdout
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read while the process runs so a full pipe can never stall it.
        var output = Data()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            output = stdout.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        if reader.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            let stopDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < stopDeadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            return nil
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    /// The XPC service does not inherit the login shell's PATH, so look in the usual install places.
    private static func locateClaude() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
