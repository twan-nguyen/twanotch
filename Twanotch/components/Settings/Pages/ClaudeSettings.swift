//
//  ClaudeSettings.swift
//  Twanotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Defaults
import SwiftUI

struct ClaudeSettings: View {
    @ObservedObject private var manager = ClaudeUsageManager.shared
    @ObservedObject private var coordinator = NotchViewCoordinator.shared
    @ObservedObject private var prompts = ClaudePromptCenter.shared
    @Default(.showClaudeUsage) var showClaudeUsage
    @Default(.answerClaudeInNotch) var answerClaudeInNotch

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showClaudeUsage) {
                    Text("Show Claude tab")
                }
                .onChange(of: showClaudeUsage) {
                    if !showClaudeUsage && coordinator.currentView == .claude {
                        coordinator.currentView = .home
                    }
                }
                Defaults.Toggle(key: .showClaudeInClosedNotch) {
                    Text("Show 5-hour session beside the closed notch")
                }
            } header: {
                Text("Display")
            } footer: {
                Text("Shows your Claude plan limits as Claude Code's /usage reports them. Twanotch asks Claude Code on this Mac for them, so it never reads your sign-in or connects to Anthropic itself.")
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { answerClaudeInNotch },
                    set: { enabled in
                        answerClaudeInNotch = enabled
                        Task { await prompts.setEnabled(enabled) }
                    }
                )) {
                    Text("Answer Claude Code in the notch")
                }
                .disabled(prompts.isConfiguring)
                ForEach([prompts.hooksProblem, prompts.serverProblem].compactMap { $0 }, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Prompts")
            } footer: {
                Text("Permission requests and questions from Claude Code on this Mac also open in the notch, and Clawd shows when Claude is working. Claude Code keeps asking as usual, and the first answer wins. Twanotch adds its hooks to ~/.claude/settings.json and keeps the original file as settings.json.twanotch-backup. Restart running Claude Code sessions to pick up the change.")
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section {
                LabeledContent("Plan") {
                    Text(manager.usage?.plan ?? "—")
                }
                LabeledContent("Status") {
                    if let problem = manager.problem {
                        Text(problem.shortTitle)
                            .foregroundStyle(.orange)
                    } else if manager.usage != nil {
                        Text("Connected")
                    } else {
                        Text("—")
                    }
                }
                LabeledContent("Last updated") {
                    if let lastUpdated = manager.lastUpdated {
                        Text(lastUpdated, format: .dateTime.hour().minute().second())
                    } else {
                        Text("—")
                    }
                }
                Button("Refresh now") {
                    Task { await manager.refresh(manual: true) }
                }
                .disabled(manager.isLoading)
            } header: {
                Text("Account")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Claude")
    }
}
