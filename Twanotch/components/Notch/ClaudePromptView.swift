//
//  ClaudePromptView.swift
//  Twanotch
//
//  Answers a Claude Code permission request or question from the open notch.
//

import SwiftUI

struct ClaudePromptView: View {
    @ObservedObject private var center = ClaudePromptCenter.shared
    let prompt: ClaudePrompt
    /// Clicks are ignored for a moment after a prompt appears, since it can open right under the pointer.
    @State private var accepting = false

    var body: some View {
        Group {
            switch prompt.content {
            case let .permission(tool, summary, detail, alwaysAllow):
                ClaudePermissionPrompt(
                    prompt: prompt, tool: tool, summary: summary, detail: detail, alwaysAllow: alwaysAllow,
                    queued: center.prompts.count - 1)
            case let .questions(questions):
                ClaudeQuestionPrompt(prompt: prompt, questions: questions, queued: center.prompts.count - 1)
            }
        }
        .id(prompt.id)
        // Controls start dimmed and brighten once they accept clicks, so the pause reads as intended.
        .disabled(!accepting)
        .animation(.easeOut(duration: 0.25), value: accepting)
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
        .transition(.opacity)
        .task(id: prompt.id) {
            accepting = false
            try? await Task.sleep(for: .milliseconds(600))
            accepting = true
        }
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
    let alwaysAllow: String?
    let queued: Int

    /// Only shell commands are checked; other tools show paths or queries that merely mention the words.
    private var isDestructive: Bool { tool == "Bash" && ClaudeCommandRisk.isDestructive(summary) }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTheme.Spacing.item) {
            ClaudePromptHeader(project: prompt.project, action: Text("wants to use \(tool)"), queued: queued)

            // The whole command stays readable: anything cut off could be the part that matters.
            FittingScrollView {
                VStack(alignment: .leading, spacing: NotchTheme.Spacing.tight) {
                    if isDestructive {
                        Label("This may not be undoable", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(NotchTheme.critical)
                    }
                    Text(summary)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(NotchTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(NotchTheme.Spacing.section)
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: NotchTheme.Radius.card).fill(NotchTheme.Fill.card))
            .overlay {
                if isDestructive {
                    RoundedRectangle(cornerRadius: NotchTheme.Radius.card)
                        .strokeBorder(NotchTheme.critical.opacity(0.7), lineWidth: 1.5)
                }
            }

            HStack(spacing: 8) {
                if let alwaysAllow {
                    Text("Always allow saves \(alwaysAllow)")
                        .font(.caption)
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(alwaysAllow)
                }
                Spacer(minLength: 8)
                Button("Deny") { center.deny(prompt) }
                    .buttonStyle(ClaudePromptButtonStyle(kind: .plain))
                if let alwaysAllow {
                    Button("Always allow") { center.allow(prompt, always: true) }
                        .buttonStyle(ClaudePromptButtonStyle(kind: .plain))
                        .help(alwaysAllow)
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
        VStack(alignment: .leading, spacing: NotchTheme.Spacing.item) {
            ClaudePromptHeader(
                project: prompt.project, action: Text(actionTitle), queued: queued, expiresAt: prompt.expiresAt)

            Text(question.text)
                .font(.headline)
                .foregroundStyle(NotchTheme.primaryText)
                .lineLimit(2)
                .help(question.text)

            // The options take whatever height is left and scroll past the tallest notch,
            // so the buttons below always stay inside it.
            FittingScrollView {
                optionGrid
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: .infinity, alignment: .top)

            HStack(spacing: NotchTheme.Spacing.item) {
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

    private var optionGrid: some View {
        LazyVGrid(columns: optionColumns, spacing: NotchTheme.Spacing.item) {
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
                                .lineLimit(usesGrid ? 1 : 2)
                                .multilineTextAlignment(.leading)
                        }
                        .font(.callout.weight(.medium))
                        .foregroundStyle(NotchTheme.primaryText)
                        if let detail = option.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(NotchTheme.secondaryText)
                                .lineLimit(usesGrid ? 1 : 3)
                        }
                    }
                    .padding(NotchTheme.Spacing.item)
                    .frame(maxWidth: .infinity, minHeight: optionHeight, alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: NotchTheme.Radius.control)
                            .fill(selection.contains(option.label) ? NotchTheme.Fill.selected : NotchTheme.Fill.card)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(ClaudeOptionButtonStyle())
                .help(option.detail ?? option.label)
            }
        }
    }

    /// Up to three short options sit side by side; more or longer ones wrap onto a two-column grid.
    private var usesGrid: Bool {
        question.options.count > 3 || question.options.contains { $0.label.count > 28 }
    }

    private var optionColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: NotchTheme.Spacing.item, alignment: .top),
            count: usesGrid ? 2 : question.options.count)
    }

    private var optionHeight: CGFloat { usesGrid ? 0 : 56 }

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
            center.extend(prompt)
            index += 1
            selection = []
        }
    }
}

/// A vertical scroll area that tells the notch how much room it leaves unused, so the open notch
/// shrinks to fit a short prompt and grows, up to its tallest, for a long one.
private struct FittingScrollView<Content: View>: View {
    @EnvironmentObject private var vm: NotchViewModel
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            content
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                    contentHeight = height
                    fit()
                }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            viewportHeight = height
            fit()
        }
    }

    private func fit() {
        guard contentHeight > 0, viewportHeight > 0 else { return }
        withAnimation(.smooth) {
            vm.fitClaudePrompt(freeSpace: viewportHeight - contentHeight)
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
                Capsule().fill(kind == .prominent ? ClaudeMascot.tint : NotchTheme.Fill.control)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

/// Option tiles dim while the prompt does not accept clicks yet.
private struct ClaudeOptionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

/// Commands that can lose work or change the system in ways that are hard to take back.
enum ClaudeCommandRisk {
    /// Where a new command can start: the beginning, or after a separator, a pipe or `sudo`-style prefix.
    private static let start = #"(^|[;&|(]\s*|\bxargs\s+|\benv\s+)"#

    private static let patterns: [NSRegularExpression] = [
        start + #"rm\s+(-[a-zA-Z]*[rRf][a-zA-Z]*\b|--recursive|--force)"#,
        start + #"sudo\b"#,
        #"\bgit\s+push\b[^;&|]*(--force|\s-f\b|--mirror|--delete|\s\+\S)"#,
        #"\bgit\s+reset\s+--hard\b"#,
        #"\bgit\s+clean\s+-[a-zA-Z]*f"#,
        #"\bgit\s+(branch|tag)\s+(-D|--delete\s+--force)\b"#,
        #"\bgit\s+checkout\s+(--\s+)?\.(\s|$)"#,
        #"\bgit\s+restore\s+\.(\s|$)"#,
        #"\bfind\b[^;&|]*\s-delete\b"#,
        start + #"(chmod|chown)\s+-R\b"#,
        start + #"(mkfs\S*|diskutil\s+erase\w*)\b"#,
        start + #"dd\s+[^;&|]*\bof="#,
        #"\b(curl|wget)\b[^|;&]*\|\s*(sudo\s+)?(ba|z)?sh\b"#,
        start + #"kill(all)?\s+-9\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.anchorsMatchLines]) }
        + [try? NSRegularExpression(pattern: #"\bDROP\s+(TABLE|DATABASE)\b"#, options: [.caseInsensitive])]
        .compactMap { $0 }

    static func isDestructive(_ command: String) -> Bool {
        // Join lines continued with a backslash so a flag on the next line still counts.
        let joined = command.replacingOccurrences(of: "\\\n", with: " ")
        let range = NSRange(joined.startIndex..., in: joined)
        return patterns.contains { $0.firstMatch(in: joined, range: range) != nil }
    }
}

/// Shown beside the closed notch while a prompt waits, so it can be found after the notch closes.
struct ClaudePromptIndicator: View {
    let count: Int
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(count > 1 ? "\(count)" : "?")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(ClaudeMascot.tint)
            .opacity(pulse ? 0.45 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = !reduceMotion }
            .onChange(of: reduceMotion) { pulse = !reduceMotion }
            .accessibilityLabel("Claude is waiting for your answer")
    }
}
