//
//  ClaudePromptView.swift
//  boringNotch
//
//  Answers a Claude Code permission request or question from the open notch.
//

import SwiftUI

struct ClaudePromptView: View {
    @ObservedObject private var center = ClaudePromptCenter.shared
    let prompt: ClaudePrompt

    var body: some View {
        Group {
            switch prompt.content {
            case let .permission(tool, summary, detail, canAlwaysAllow):
                ClaudePermissionPrompt(
                    prompt: prompt, tool: tool, summary: summary, detail: detail, canAlwaysAllow: canAlwaysAllow,
                    queued: center.prompts.count - 1)
            case let .questions(questions):
                ClaudeQuestionPrompt(prompt: prompt, questions: questions, queued: center.prompts.count - 1)
            }
        }
        .id(prompt.id)
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
        .transition(.opacity)
    }
}

private struct ClaudePromptHeader: View {
    let project: String
    let action: Text
    let queued: Int
    var expiresAt: Date?

    var body: some View {
        HStack(spacing: 6) {
            ClaudeMascot()
                .fill(ClaudeMascot.tint)
                .frame(width: 15, height: 10)
            Text(project)
                .foregroundStyle(.white)
                .lineLimit(1)
            action
                .foregroundStyle(.gray)
                .lineLimit(1)
            Spacer(minLength: 8)
            if queued > 0 {
                Text("+\(queued) waiting")
                    .foregroundStyle(.gray)
            }
            if let expiresAt {
                Text(timerInterval: Date.now...max(expiresAt, .now), countsDown: true)
                    .monospacedDigit()
                    .foregroundStyle(.gray)
                    .frame(width: 34, alignment: .trailing)
                    .help("Goes back to Claude Code when the time runs out")
            }
        }
        .font(.caption)
    }
}

private struct ClaudePermissionPrompt: View {
    @ObservedObject private var center = ClaudePromptCenter.shared
    let prompt: ClaudePrompt
    let tool: String
    let summary: String
    let detail: String?
    let canAlwaysAllow: Bool
    let queued: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ClaudePromptHeader(project: prompt.project, action: Text("wants to use \(tool)"), queued: queued)

            VStack(alignment: .leading, spacing: 4) {
                Text(summary)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
            .help(summary)

            HStack(spacing: 8) {
                Spacer()
                Button("Deny") { center.deny(prompt) }
                    .buttonStyle(ClaudePromptButtonStyle(kind: .plain))
                if canAlwaysAllow {
                    Button("Always allow") { center.allow(prompt, always: true) }
                        .buttonStyle(ClaudePromptButtonStyle(kind: .plain))
                        .help("Allow, and do not ask again for similar requests")
                }
                Button("Allow") { center.allow(prompt) }
                    .buttonStyle(ClaudePromptButtonStyle(kind: .prominent))
            }
        }
    }
}

private struct ClaudeQuestionPrompt: View {
    @ObservedObject private var center = ClaudePromptCenter.shared
    let prompt: ClaudePrompt
    let questions: [ClaudeQuestion]
    let queued: Int

    @State private var index = 0
    @State private var answers: [String: String] = [:]
    @State private var selection: Set<String> = []

    private var question: ClaudeQuestion { questions[index] }
    private var isLast: Bool { index == questions.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ClaudePromptHeader(
                project: prompt.project, action: Text(actionTitle), queued: queued, expiresAt: prompt.expiresAt)

            Text(question.text)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(2)
                .help(question.text)

            HStack(spacing: 8) {
                ForEach(question.options) { option in
                    Button {
                        choose(option)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                if question.allowsMultiple {
                                    Image(systemName: selection.contains(option.label) ? "checkmark.square.fill" : "square")
                                }
                                Text(option.label)
                                    .lineLimit(1)
                            }
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.white)
                            if let detail = option.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.gray)
                                    .lineLimit(2)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(selection.contains(option.label) ? 0.2 : 0.08))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(option.detail ?? option.label)
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 8) {
                Button("Answer in Claude Code") { center.handBack(prompt) }
                    .buttonStyle(ClaudePromptButtonStyle(kind: .plain))
                    .help("Type your own answer or pick there instead")
                Spacer()
                if question.allowsMultiple {
                    Button(isLast ? "Send" : "Next") { commit(Array(selection)) }
                        .buttonStyle(ClaudePromptButtonStyle(kind: .prominent))
                        .disabled(selection.isEmpty)
                }
            }
        }
    }

    private var actionTitle: String {
        let title = question.header.map { String(localized: "asks · \($0)") } ?? String(localized: "asks")
        guard questions.count > 1 else { return title }
        return title + " (\(index + 1)/\(questions.count))"
    }

    private func choose(_ option: ClaudeQuestion.Option) {
        if question.allowsMultiple {
            if selection.contains(option.label) {
                selection.remove(option.label)
            } else {
                selection.insert(option.label)
            }
        } else {
            commit([option.label])
        }
    }

    private func commit(_ labels: [String]) {
        // Keep the options' own order for multi-select answers.
        let ordered = question.options.map(\.label).filter(labels.contains)
        answers[question.text] = ordered.joined(separator: ", ")
        if isLast {
            center.answer(prompt, with: answers)
        } else {
            index += 1
            selection = []
        }
    }
}

private struct ClaudePromptButtonStyle: ButtonStyle {
    enum Kind { case plain, prominent }
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(kind == .prominent ? .semibold : .regular))
            .foregroundStyle(kind == .prominent ? .black : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(kind == .prominent ? ClaudeMascot.tint : Color.white.opacity(0.12))
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

/// Shown beside the closed notch while a prompt waits, so it can be found after the notch closes.
struct ClaudePromptIndicator: View {
    let count: Int
    @State private var pulse = false

    var body: some View {
        Text(count > 1 ? "\(count)" : "?")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(ClaudeMascot.tint)
            .opacity(pulse ? 0.45 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .accessibilityLabel("Claude is waiting for your answer")
    }
}
