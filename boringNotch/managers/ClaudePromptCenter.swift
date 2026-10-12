//
//  ClaudePromptCenter.swift
//  boringNotch
//
//  Queue of Claude Code permission requests and questions waiting for an answer in the notch.
//  Claude Code still shows its own prompt alongside; whichever is answered first wins, and an
//  unanswered prompt goes back to Claude Code after a while.
//

import Defaults
import Foundation

struct ClaudeQuestion: Identifiable {
    struct Option: Identifiable {
        let label: String
        let detail: String?
        var id: String { label }
    }

    let text: String
    let header: String?
    let options: [Option]
    let allowsMultiple: Bool
    var id: String { text }
}

struct ClaudePrompt: Identifiable {
    enum Content {
        case permission(tool: String, summary: String, detail: String?, canAlwaysAllow: Bool)
        case questions([ClaudeQuestion])
    }

    let id: UUID
    let project: String
    let content: Content
    let expiresAt: Date
}

@MainActor
final class ClaudePromptCenter: ObservableObject {
    static let shared = ClaudePromptCenter()

    @Published private(set) var prompts: [ClaudePrompt] = []
    /// Why the hooks or the local endpoint are not working, if they are not.
    @Published private(set) var problem: String?
    @Published private(set) var isConfiguring = false

    /// Questions block Claude Code's own picker while they wait, so they go back to it sooner.
    private static let questionWait: TimeInterval = 30
    /// Kept under the hook's 300-second timeout so Claude Code gets an answer before it gives up.
    private static let permissionWait: TimeInterval = 290

    private var server: ClaudePromptServer?
    /// Pieces of the original hook input that the reply has to echo back.
    private var questionInputs: [UUID: Any] = [:]
    private var permissionSuggestions: [UUID: Any] = [:]
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]

    private init() {}

    var current: ClaudePrompt? { prompts.first }

    /// Starts listening and re-checks the hooks when the feature was left on.
    func start() {
        guard Defaults[.answerClaudeInNotch] else { return }
        Task { await setEnabled(true) }
    }

    func setEnabled(_ enabled: Bool) async {
        isConfiguring = true
        defer { isConfiguring = false }

        if Defaults[.claudePromptToken].isEmpty {
            Defaults[.claudePromptToken] = UUID().uuidString
        }
        if enabled {
            startServer()
        } else {
            stopServer()
        }
        let failure = await XPCHelperClient.shared.configureClaudeHooks(
            install: enabled, port: Int(ClaudePromptServer.port), token: Defaults[.claudePromptToken])
        if let failure {
            problem = failure
        } else if !enabled {
            problem = nil
        }
    }

    // MARK: - Answers

    func allow(_ prompt: ClaudePrompt, always: Bool = false) {
        var decision: [String: Any] = ["behavior": "allow"]
        if always, let suggestions = permissionSuggestions[prompt.id] {
            decision["updatedPermissions"] = suggestions
        }
        finish(prompt.id, with: ["hookEventName": "PermissionRequest", "decision": decision])
    }

    func deny(_ prompt: ClaudePrompt) {
        finish(prompt.id, with: [
            "hookEventName": "PermissionRequest",
            "decision": ["behavior": "deny", "message": "The user denied this from the notch."],
        ])
    }

    /// `answers` maps each question's text to the chosen label, multiple labels joined with ", ".
    func answer(_ prompt: ClaudePrompt, with answers: [String: String]) {
        guard let questions = questionInputs[prompt.id] else { return }
        finish(prompt.id, with: [
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "updatedInput": ["questions": questions, "answers": answers],
        ])
    }

    /// Leaves the prompt to Claude Code's own UI.
    func handBack(_ prompt: ClaudePrompt) {
        finish(prompt.id, with: nil)
    }

    private func finish(_ id: UUID, with output: [String: Any]?) {
        guard prompts.contains(where: { $0.id == id }) else { return }
        var body = Data()
        if let output, let data = try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": output]) {
            body = data
        }
        server?.respond(id, body: body)
        forget(id)
    }

    private func forget(_ id: UUID) {
        prompts.removeAll { $0.id == id }
        questionInputs[id] = nil
        permissionSuggestions[id] = nil
        expiryTasks.removeValue(forKey: id)?.cancel()
    }

    // MARK: - Server

    private func startServer() {
        guard server == nil else { return }
        let server = ClaudePromptServer(token: Defaults[.claudePromptToken])
        server.onCall = { call in
            Task { @MainActor in ClaudePromptCenter.shared.receive(call) }
        }
        server.onAbandon = { id in
            Task { @MainActor in ClaudePromptCenter.shared.forget(id) }
        }
        server.onStateChange = { message in
            Task { @MainActor in
                ClaudePromptCenter.shared.problem = message.map {
                    String(localized: "Port \(String(ClaudePromptServer.port)) is unavailable: \($0)")
                }
            }
        }
        server.start()
        self.server = server
    }

    private func stopServer() {
        server?.stop()
        server = nil
        for id in prompts.map(\.id) {
            forget(id)
        }
    }

    private func receive(_ call: ClaudeHookCall) {
        guard let body = try? JSONSerialization.jsonObject(with: call.body) as? [String: Any],
              let toolName = body["tool_name"] as? String
        else {
            server?.respond(call.id, body: Data())
            return
        }
        let input = body["tool_input"] as? [String: Any] ?? [:]
        let project = (body["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Claude Code"

        let content: ClaudePrompt.Content
        let wait: TimeInterval
        switch call.kind {
        case .permission:
            // Questions arrive through their own hook, and plan approval needs the full plan in view.
            guard toolName != "AskUserQuestion", toolName != "ExitPlanMode" else {
                server?.respond(call.id, body: Data())
                return
            }
            let suggestions = body["permission_suggestions"] as? [Any] ?? []
            if !suggestions.isEmpty {
                permissionSuggestions[call.id] = suggestions
            }
            let (summary, detail) = Self.describe(tool: toolName, input: input)
            content = .permission(
                tool: Self.displayName(of: toolName), summary: summary, detail: detail,
                canAlwaysAllow: !suggestions.isEmpty)
            wait = Self.permissionWait
        case .question:
            guard let rawQuestions = input["questions"] as? [[String: Any]] else {
                server?.respond(call.id, body: Data())
                return
            }
            let questions = rawQuestions.compactMap(Self.question)
            guard questions.count == rawQuestions.count, !questions.isEmpty else {
                server?.respond(call.id, body: Data())
                return
            }
            questionInputs[call.id] = rawQuestions
            content = .questions(questions)
            wait = Self.questionWait
        }

        let prompt = ClaudePrompt(
            id: call.id, project: project, content: content, expiresAt: Date().addingTimeInterval(wait))
        prompts.append(prompt)
        expiryTasks[call.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.finish(call.id, with: nil)
        }
    }

    // MARK: - Describing tool calls

    private static func question(_ raw: [String: Any]) -> ClaudeQuestion? {
        guard let text = raw["question"] as? String,
              let rawOptions = raw["options"] as? [[String: Any]]
        else { return nil }
        let options = rawOptions.compactMap { option -> ClaudeQuestion.Option? in
            guard let label = option["label"] as? String else { return nil }
            return ClaudeQuestion.Option(label: label, detail: option["description"] as? String)
        }
        guard !options.isEmpty else { return nil }
        return ClaudeQuestion(
            text: text, header: raw["header"] as? String, options: options,
            allowsMultiple: raw["multiSelect"] as? Bool ?? false)
    }

    private static func displayName(of tool: String) -> String {
        // mcp__server__tool reads better as "server · tool".
        let parts = tool.components(separatedBy: "__")
        if parts.count >= 3, parts[0] == "mcp" {
            return parts[1] + " · " + parts[2...].joined(separator: "__")
        }
        return tool
    }

    /// The line the notch shows for a tool call, plus an optional second line.
    private static func describe(tool: String, input: [String: Any]) -> (String, String?) {
        let description = input["description"] as? String
        if let command = input["command"] as? String {
            return (command, description)
        }
        for key in ["file_path", "notebook_path", "path"] {
            if let path = input[key] as? String {
                return ((path as NSString).abbreviatingWithTildeInPath, description)
            }
        }
        if let url = input["url"] as? String {
            return (url, input["prompt"] as? String)
        }
        if let query = input["query"] as? String {
            return (query, nil)
        }
        if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]),
           let json = String(data: data, encoding: .utf8), json != "{}"
        {
            return (json, description)
        }
        return (tool, description)
    }
}
