//
//  ClaudePromptCenter.swift
//  Twanotch
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
        /// `alwaysAllow` describes the rules "Always allow" would save, when Claude Code offered any.
        case permission(tool: String, summary: String, detail: String?, alwaysAllow: String?)
        case questions([ClaudeQuestion])
    }

    let id: UUID
    let project: String
    let content: Content
    let receivedAt: Date
    var expiresAt: Date

    var isQuestion: Bool {
        if case .questions = content { return true }
        return false
    }
}

/// What Clawd acts out in the notch.
enum ClawdActivity {
    case idle, working, waiting
}

@MainActor
final class ClaudePromptCenter: ObservableObject {
    static let shared = ClaudePromptCenter()

    @Published private(set) var prompts: [ClaudePrompt] = []
    /// Why the local endpoint is not listening, if it is not.
    @Published private(set) var serverProblem: String?
    /// Why the hooks in Claude Code's settings could not be changed, if they could not.
    @Published private(set) var hooksProblem: String?
    @Published private(set) var isConfiguring = false
    /// Claude Code sessions between a prompt and the end of their turn.
    @Published private(set) var workingSessions: Set<String> = []

    /// Questions block Claude Code's own picker while they wait, so they go back to it sooner.
    /// The clock starts once the question is on screen.
    private static let questionWait: TimeInterval = 30
    /// Answering one of several questions buys time up to this long after arrival, under the hook's 60 seconds.
    private static let questionLimit: TimeInterval = 55
    /// Kept under the hook's 300-second timeout so Claude Code gets an answer before it gives up.
    private static let permissionWait: TimeInterval = 290
    private static let serverRetryDelay: TimeInterval = 10

    private var server: ClaudePromptServer?
    /// The original tool input, which the answer to a question has to echo back in full.
    private var questionInputs: [UUID: [String: Any]] = [:]
    /// The rule suggestions "Always allow" applies.
    private var alwaysAllowRules: [UUID: [[String: Any]]] = [:]
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]
    private var retryTask: Task<Void, Never>?
    private var lastActivity: [String: Date] = [:]
    private var staleActivityTask: Task<Void, Never>?
    /// An interrupted turn sends no Stop, so a session that has gone quiet this long counts as idle.
    private static let activityTimeout: TimeInterval = 10 * 60

    private init() {}

    var current: ClaudePrompt? { prompts.first }

    var activity: ClawdActivity {
        if !prompts.isEmpty { return .waiting }
        return workingSessions.isEmpty ? .idle : .working
    }

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
        hooksProblem = failure.map { String(localized: "Could not update Claude Code settings: \($0)") }
        if failure != nil, enabled {
            // Without the hooks nothing reaches the notch, so the toggle should not claim otherwise.
            Defaults[.answerClaudeInNotch] = false
            stopServer()
        }
    }

    // MARK: - Answers

    func allow(_ prompt: ClaudePrompt, always: Bool = false) {
        var decision: [String: Any] = ["behavior": "allow"]
        if always, let rules = alwaysAllowRules[prompt.id] {
            decision["updatedPermissions"] = rules
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
        guard var input = questionInputs[prompt.id] else { return }
        input["answers"] = answers
        finish(prompt.id, with: [
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "updatedInput": input,
        ])
    }

    /// Called as each of several questions is answered, so the rest are not cut short.
    func extend(_ prompt: ClaudePrompt) {
        guard prompt.isQuestion else { return }
        schedule(prompt.id, until: prompt.receivedAt.addingTimeInterval(Self.questionLimit))
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
        alwaysAllowRules[id] = nil
        expiryTasks.removeValue(forKey: id)?.cancel()
        startQuestionClock()
    }

    /// A question waiting behind another prompt has not been seen, so its time starts when it comes up.
    private func startQuestionClock() {
        guard let current, current.isQuestion, expiryTasks[current.id] == nil else { return }
        let limit = current.receivedAt.addingTimeInterval(Self.questionLimit)
        schedule(current.id, until: min(Date().addingTimeInterval(Self.questionWait), limit))
    }

    private func schedule(_ id: UUID, until deadline: Date) {
        guard let index = prompts.firstIndex(where: { $0.id == id }) else { return }
        prompts[index].expiresAt = deadline
        expiryTasks[id]?.cancel()
        expiryTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.finish(id, with: nil)
        }
    }

    // MARK: - Server

    private func startServer() {
        retryTask?.cancel()
        retryTask = nil
        guard server == nil else { return }
        let server = ClaudePromptServer(token: Defaults[.claudePromptToken])
        server.onCall = { [weak server] call in
            Task { @MainActor in ClaudePromptCenter.shared.receive(call, from: server) }
        }
        server.onAbandon = { id in
            Task { @MainActor in ClaudePromptCenter.shared.forget(id) }
        }
        server.onStateChange = { [weak server] message in
            Task { @MainActor in ClaudePromptCenter.shared.serverStateChanged(message, server: server) }
        }
        server.start()
        self.server = server
    }

    private func stopServer() {
        retryTask?.cancel()
        retryTask = nil
        server?.stop()
        server = nil
        serverProblem = nil
        for id in prompts.map(\.id) {
            forget(id)
        }
        workingSessions = []
        lastActivity = [:]
    }

    /// A server that failed has stopped itself; try a fresh one in a moment, for instance once
    /// another copy of the app has let go of the port.
    private func serverStateChanged(_ message: String?, server failed: ClaudePromptServer?) {
        guard let failed, failed === server else { return }
        serverProblem = message.map {
            String(localized: "Port \(String(ClaudePromptServer.port)) is unavailable: \($0)")
        }
        guard message != nil else { return }
        server = nil
        for id in prompts.map(\.id) {
            forget(id)
        }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.serverRetryDelay))
            guard !Task.isCancelled, Defaults[.answerClaudeInNotch] else { return }
            self?.startServer()
        }
    }

    private func receive(_ call: ClaudeHookCall, from origin: ClaudePromptServer?) {
        // A call from a server that has since been stopped or replaced falls back to Claude Code.
        guard let origin, origin === server else {
            origin?.respond(call.id, body: Data())
            return
        }
        if call.kind == .event {
            noteActivity(call.body)
            return
        }
        guard let body = try? JSONSerialization.jsonObject(with: call.body) as? [String: Any],
              let toolName = body["tool_name"] as? String
        else {
            origin.respond(call.id, body: Data())
            return
        }
        let input = body["tool_input"] as? [String: Any] ?? [:]
        let project = Self.projectName(cwd: body["cwd"] as? String)
        let now = Date()

        let content: ClaudePrompt.Content
        switch call.kind {
        case .permission:
            // Questions arrive through their own hook, and plan approval needs the full plan in view.
            guard toolName != "AskUserQuestion", toolName != "ExitPlanMode" else {
                origin.respond(call.id, body: Data())
                return
            }
            let rules = Self.alwaysAllowRules(in: body["permission_suggestions"])
            if !rules.isEmpty {
                alwaysAllowRules[call.id] = rules
            }
            let (summary, detail) = Self.describe(tool: toolName, input: input)
            content = .permission(
                tool: Self.displayName(of: toolName), summary: summary, detail: detail,
                alwaysAllow: rules.isEmpty ? nil : Self.describe(rules: rules))
        case .question:
            guard let rawQuestions = input["questions"] as? [[String: Any]] else {
                origin.respond(call.id, body: Data())
                return
            }
            let questions = rawQuestions.compactMap(Self.question)
            guard questions.count == rawQuestions.count, !questions.isEmpty else {
                origin.respond(call.id, body: Data())
                return
            }
            questionInputs[call.id] = input
            content = .questions(questions)
        case .event:
            return
        }

        let prompt = ClaudePrompt(id: call.id, project: project, content: content, receivedAt: now, expiresAt: now)
        if prompt.isQuestion {
            // Questions hold up Claude Code until answered, so they go ahead of permission requests.
            let index = prompts.firstIndex { !$0.isQuestion } ?? prompts.endIndex
            prompts.insert(prompt, at: index)
            startQuestionClock()
        } else {
            prompts.append(prompt)
            schedule(call.id, until: now.addingTimeInterval(Self.permissionWait))
        }
    }

    // MARK: - Activity

    private func noteActivity(_ data: Data) {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = body["session_id"] as? String,
              let event = body["hook_event_name"] as? String
        else { return }

        switch event {
        case "UserPromptSubmit", "PreToolUse":
            lastActivity[session] = Date()
            if !workingSessions.contains(session) {
                workingSessions.insert(session)
            }
            watchForStaleActivity()
        case "Stop", "StopFailure", "SessionEnd":
            lastActivity[session] = nil
            workingSessions.remove(session)
        default:
            break
        }
    }

    private func watchForStaleActivity() {
        guard staleActivityTask == nil else { return }
        staleActivityTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                let cutoff = Date().addingTimeInterval(-Self.activityTimeout)
                for (session, seen) in self.lastActivity where seen < cutoff {
                    self.lastActivity[session] = nil
                    self.workingSessions.remove(session)
                }
                if self.workingSessions.isEmpty {
                    self.staleActivityTask = nil
                    return
                }
            }
        }
    }

    /// The folder name, except for the scratch folders Claude Desktop makes for sessions without a project.
    private static func projectName(cwd: String?) -> String {
        guard let cwd else { return "Claude Code" }
        if cwd.contains("/Application Support/Claude/scratch-workspaces/") {
            return "Claude Desktop"
        }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    // MARK: - Always allow

    /// Only plain "allow" rules are offered; mode changes and extra directories stay in Claude Code's own prompt.
    private static func alwaysAllowRules(in value: Any?) -> [[String: Any]] {
        guard let suggestions = value as? [[String: Any]] else { return [] }
        return suggestions.filter { suggestion in
            guard suggestion["type"] as? String == "addRules",
                  suggestion["behavior"] as? String == "allow",
                  let rules = suggestion["rules"] as? [[String: Any]], !rules.isEmpty
            else { return false }
            return rules.allSatisfy { $0["toolName"] is String }
        }
    }

    /// For example "Bash(npm run lint:*) · this project".
    private static func describe(rules suggestions: [[String: Any]]) -> String {
        suggestions.map { suggestion in
            let rules = (suggestion["rules"] as? [[String: Any]] ?? []).compactMap { rule -> String? in
                guard let tool = rule["toolName"] as? String else { return nil }
                guard let content = rule["ruleContent"] as? String, !content.isEmpty else { return tool }
                return "\(tool)(\(content))"
            }
            let place: String
            switch suggestion["destination"] as? String {
            case "session": place = String(localized: "this session")
            case "userSettings": place = String(localized: "all projects")
            case "projectSettings", "localSettings": place = String(localized: "this project")
            default: place = String(localized: "Claude Code settings")
            }
            return rules.joined(separator: ", ") + " · " + place
        }
        .joined(separator: "; ")
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
