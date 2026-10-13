//
//  ClaudeUsageView.swift
//  Twanotch
//
//  The Claude tab: Clawd with what Claude is doing, beside the plan's usage limits.
//

import Defaults
import SwiftUI

struct ClaudeUsageView: View {
    @ObservedObject private var manager = ClaudeUsageManager.shared

    var body: some View {
        HStack(alignment: .top, spacing: NotchTheme.Spacing.section) {
            ClaudeStatusPanel()
                .frame(width: 150)
            content
                .padding(.horizontal, 12)
                .padding(.vertical, NotchTheme.Spacing.item)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: NotchTheme.Radius.card).fill(NotchTheme.Fill.card))
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
        .task {
            // Polls only while the tab is on screen; the task is cancelled when it disappears.
            while !Task.isCancelled {
                await manager.refresh()
                try? await Task.sleep(for: .seconds(ClaudeUsageManager.refreshInterval))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let usage = manager.usage, !usage.windows.isEmpty {
            // The rows spread over the card but can close up to fit three limits.
            VStack(spacing: 0) {
                ForEach(Array(usage.windows.enumerated()), id: \.element.id) { index, window in
                    if index > 0 {
                        Spacer(minLength: NotchTheme.Spacing.tight)
                    }
                    ClaudeUsageRow(window: window)
                }
            }
            .frame(maxHeight: .infinity)
        } else if let problem = manager.problem {
            ClaudeUsageProblemView(problem: problem)
        } else if manager.usage != nil {
            ClaudeUsageMessage(
                symbol: "checkmark.circle",
                title: "No usage limits reported",
                detail: "Claude did not return any usage windows for this account."
            )
        } else {
            VStack(spacing: NotchTheme.Spacing.section) {
                ForEach(0..<2, id: \.self) { _ in
                    ShimmerSkeleton()
                        .frame(height: 30)
                }
            }
            .frame(maxHeight: .infinity)
            .accessibilityLabel("Loading Claude usage")
        }
    }
}

/// Clawd and what Claude is up to, with the plan and when usage was last read.
private struct ClaudeStatusPanel: View {
    @ObservedObject private var manager = ClaudeUsageManager.shared
    @ObservedObject private var prompts = ClaudePromptCenter.shared
    @Default(.answerClaudeInNotch) private var answerClaudeInNotch
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ClawdView(activity: prompts.activity, size: CGSize(width: 46, height: 32))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 6) {
                Text("Claude")
                    .font(.headline)
                    .foregroundStyle(NotchTheme.primaryText)
                if let plan = manager.usage?.plan {
                    Text(plan)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(NotchTheme.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(NotchTheme.Fill.track))
                        .lineLimit(1)
                }
            }

            // Claude Code only reports what it is doing through the hooks the notch installs.
            if answerClaudeInNotch {
                activityLine
            }

            HStack(spacing: 4) {
                if manager.usage != nil, let problem = manager.problem {
                    Label(problem.shortTitle, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(NotchTheme.warning)
                        .lineLimit(1)
                } else if let lastUpdated = manager.lastUpdated {
                    // Minutes, not seconds: a label ticking every second keeps shifting the text.
                    TimelineView(.everyMinute) { context in
                        updatedLabel(lastUpdated, now: context.date)
                    }
                    .lineLimit(1)
                    .monospacedDigit()
                }
                Spacer(minLength: 0)
                refreshButton
            }
            .font(.caption2)
            .foregroundStyle(NotchTheme.secondaryText)
        }
        .padding(.horizontal, NotchTheme.Spacing.section)
        .padding(.vertical, NotchTheme.Spacing.item)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: NotchTheme.Radius.card).fill(NotchTheme.Fill.card))
    }

    private func updatedLabel(_ date: Date, now: Date) -> Text {
        guard now.timeIntervalSince(date) >= 60 else { return Text("Updated just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        // Match the language the interface is shown in, which can differ from the system's.
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return Text("Updated \(formatter.localizedString(for: date, relativeTo: now))")
    }

    private var activityLine: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(activityColor)
                .frame(width: 6, height: 6)
            activityText
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.caption)
        .foregroundStyle(prompts.activity == .idle ? NotchTheme.secondaryText : NotchTheme.primaryText)
        .animation(.smooth, value: prompts.activity)
    }

    private var activityText: Text {
        switch prompts.activity {
        case .idle: Text("Idle")
        case .waiting: Text("Waiting for you")
        case .working:
            prompts.workingSessions.count > 1
                ? Text("Working · \(prompts.workingSessions.count) sessions")
                : Text("Working")
        }
    }

    private var activityColor: Color {
        switch prompts.activity {
        case .idle: NotchTheme.secondaryText
        case .working: .green
        case .waiting: ClaudeMascot.tint
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await manager.refresh(manual: true) }
        } label: {
            Image(systemName: "arrow.clockwise")
                .rotationEffect(.degrees(manager.isLoading && !reduceMotion ? 360 : 0))
                .opacity(manager.isLoading && reduceMotion ? 0.5 : 1)
                .animation(
                    manager.isLoading && !reduceMotion
                        ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                    value: manager.isLoading
                )
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(manager.isLoading)
        .help("Refresh")
        .accessibilityLabel("Refresh Claude usage")
    }
}

/// One usage limit on a line: its name and reset time above, what is left as a bar and a percentage.
private struct ClaudeUsageRow: View {
    let window: ClaudeUsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(NotchTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: NotchTheme.Spacing.item)
                resetLabel
                    .font(.caption2)
                    .foregroundStyle(NotchTheme.secondaryText)
                    .lineLimit(1)
            }

            HStack(spacing: NotchTheme.Spacing.item) {
                remainingBar
                Text("\(Int(window.remainingPercent.rounded()))%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(window.remainingTint ?? NotchTheme.primaryText)
                    .contentTransition(.numericText())
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .animation(.smooth, value: window.usedPercent)
        .accessibilityElement(children: .combine)
    }

    /// What is left, with a tick where an even pace through the window would be now.
    private var remainingBar: some View {
        let pace = window.evenPaceRemaining()
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(NotchTheme.Fill.track)
                    .frame(height: 5)
                Capsule()
                    .fill(window.remainingTint ?? ClaudeMascot.tint)
                    .frame(width: geo.size.width * window.remainingPercent / 100, height: 5)
                if let pace {
                    Capsule()
                        .fill(NotchTheme.primaryText.opacity(0.8))
                        .frame(width: 2, height: 9)
                        .offset(x: min(max(geo.size.width * pace / 100 - 1, 0), geo.size.width - 2))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 9)
        .help(pace.map { Text("At an even pace, \(Int($0.rounded()))% would be left now") } ?? Text(""))
    }

    private var title: LocalizedStringKey {
        switch window.kind {
        case .session: "5-hour session"
        case .weekly: "Weekly"
        case .model(let name): "Weekly · \(name)"
        }
    }

    @ViewBuilder
    private var resetLabel: some View {
        if let resetsAt = window.resetsAt, resetsAt > Date() {
            if resetsAt.timeIntervalSinceNow < 24 * 60 * 60 {
                Text("Resets in \(Text(resetsAt, style: .relative))")
            } else {
                Text("Resets \(Text(resetsAt, format: .dateTime.weekday(.abbreviated).hour().minute()))")
            }
        } else {
            Text("Not started")
        }
    }
}

private struct ClaudeUsageProblemView: View {
    let problem: ClaudeUsageProblem

    var body: some View {
        switch problem {
        case .notInstalled:
            ClaudeUsageMessage(
                symbol: "terminal",
                title: "Claude Code not found",
                detail: "Install Claude Code and sign in; Twanotch reads usage through it."
            )
        case .notSignedIn:
            ClaudeUsageMessage(
                symbol: "person.crop.circle.badge.questionmark",
                title: "Not signed in to Claude Code",
                detail: "Run claude in Terminal and sign in, then come back here."
            )
        case .unavailable(let message):
            ClaudeUsageMessage(
                symbol: "exclamationmark.triangle",
                title: "Couldn't load Claude usage",
                detail: LocalizedStringKey(message)
            )
        }
    }
}

private struct ClaudeUsageMessage: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(ClaudeMascot.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(NotchTheme.primaryText)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(NotchTheme.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension ClaudeUsageProblem {
    var shortTitle: LocalizedStringKey {
        switch self {
        case .notInstalled: "Claude Code not found"
        case .notSignedIn: "Not signed in"
        case .unavailable: "Unavailable"
        }
    }
}

/// Claude Code's pixel mascot, drawn from a 12×8 grid so it stays sharp at any size.
struct ClaudeMascot: Shape {
    static let tint = Color(red: 0.85, green: 0.47, blue: 0.34)
    /// Tab icon name that TabButton draws as this shape instead of an SF Symbol.
    static let tabIcon = "claude.mascot"

    private static let rows = [
        "..########..",
        "..#.####.#..",
        "############",
        "############",
        "..########..",
        "..########..",
        "..#.#..#.#..",
        "..#.#..#.#.."
    ]

    func path(in rect: CGRect) -> Path {
        let columns = CGFloat(Self.rows[0].count)
        let cell = min(rect.width / columns, rect.height / CGFloat(Self.rows.count))
        let origin = CGPoint(
            x: rect.midX - cell * columns / 2,
            y: rect.midY - cell * CGFloat(Self.rows.count) / 2
        )
        var path = Path()
        for (row, line) in Self.rows.enumerated() {
            for (column, pixel) in line.enumerated() where pixel == "#" {
                path.addRect(CGRect(
                    x: origin.x + CGFloat(column) * cell,
                    y: origin.y + CGFloat(row) * cell,
                    width: cell,
                    height: cell
                ))
            }
        }
        return path
    }
}

extension ClaudeUsageWindow {
    var remainingPercent: Double {
        100 - usedPercent
    }

    /// How long the window lasts before it resets.
    var duration: TimeInterval {
        switch kind {
        case .session: 5 * 60 * 60
        case .weekly, .model: 7 * 24 * 60 * 60
        }
    }

    /// The percentage that would be left now if usage were spread evenly until the reset;
    /// nil while the window has not started.
    func evenPaceRemaining(at now: Date = .now) -> Double? {
        guard let resetsAt, resetsAt > now else { return nil }
        return min(max(resetsAt.timeIntervalSince(now) / duration, 0), 1) * 100
    }

    /// Warning color once little is left; `nil` while there is plenty.
    var remainingTint: Color? {
        switch remainingPercent {
        case ..<10: .red
        case 10..<25: .orange
        default: nil
        }
    }
}

/// The session's remaining percentage beside the closed notch.
struct ClaudeClosedNotchPercent: View {
    let window: ClaudeUsageWindow

    var body: some View {
        Text("\(Int(window.remainingPercent.rounded()))%")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(window.remainingTint ?? NotchTheme.primaryText)
            .lineLimit(1)
            // "100%" only just fits the space beside the notch, so let it shrink rather than clip.
            .minimumScaleFactor(0.75)
            .contentTransition(.numericText())
            .accessibilityLabel(Text("Claude 5-hour session: \(Int(window.remainingPercent.rounded()))% left"))
    }
}
