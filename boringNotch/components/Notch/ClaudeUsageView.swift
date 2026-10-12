//
//  ClaudeUsageView.swift
//  boringNotch
//
//  The Claude tab: plan usage windows with their reset times.
//

import SwiftUI

struct ClaudeUsageView: View {
    @ObservedObject private var manager = ClaudeUsageManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
                .frame(maxHeight: .infinity)
            footer
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
            HStack(spacing: 10) {
                ForEach(usage.windows) { window in
                    ClaudeUsageCard(window: window)
                }
            }
        } else if let problem = manager.problem {
            ClaudeUsageProblemView(problem: problem)
        } else if manager.usage != nil {
            ClaudeUsageMessage(
                symbol: "checkmark.circle",
                title: "No usage limits reported",
                detail: "Claude did not return any usage windows for this account."
            )
        } else {
            HStack(spacing: 10) {
                ForEach(0..<2, id: \.self) { _ in
                    ShimmerSkeleton(cornerRadius: 12)
                }
            }
            .accessibilityLabel("Loading Claude usage")
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            ClaudeMascot()
                .fill(ClaudeMascot.tint)
                .frame(width: 15, height: 10)
            Text("Claude")
                .foregroundStyle(.white)
            if let plan = manager.usage?.plan {
                Text(plan)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
            }

            Spacer(minLength: 8)

            if manager.usage != nil, let problem = manager.problem {
                Label(problem.shortTitle, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if let lastUpdated = manager.lastUpdated {
                Text("Updated \(Text(lastUpdated, style: .relative)) ago")
                    .lineLimit(1)
            }

            Button {
                Task { await manager.refresh(manual: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(manager.isLoading ? 360 : 0))
                    .animation(
                        manager.isLoading ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                        value: manager.isLoading
                    )
            }
            .buttonStyle(.plain)
            .disabled(manager.isLoading)
            .help("Refresh")
            .accessibilityLabel("Refresh Claude usage")
        }
        .font(.caption)
        .foregroundStyle(.gray)
    }
}

private struct ClaudeUsageCard: View {
    let window: ClaudeUsageWindow


    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.gray)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(window.remainingPercent.rounded()))%")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text("left")
                    .font(.caption)
                    .foregroundStyle(.gray)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(window.remainingTint ?? ClaudeMascot.tint)
                        .frame(width: geo.size.width * window.remainingPercent / 100)
                }
            }
            .frame(height: 5)

            resetLabel
                .font(.caption2)
                .foregroundStyle(.gray)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
        .animation(.smooth, value: window.usedPercent)
        .accessibilityElement(children: .combine)
    }

    private var title: LocalizedStringKey {
        switch window.kind {
        case .session: "5-hour session"
        case .weekly: "Weekly"
        case .sonnet: "Weekly · Sonnet"
        case .opus: "Weekly · Opus"
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
        case .notSignedIn:
            ClaudeUsageMessage(
                symbol: "person.crop.circle.badge.questionmark",
                title: "Not signed in to Claude Code",
                detail: "Run claude in Terminal and sign in, then come back here."
            )
        case .expired:
            ClaudeUsageMessage(
                symbol: "clock.badge.exclamationmark",
                title: "Claude Code sign-in expired",
                detail: "Run claude in Terminal once so it refreshes its sign-in."
            )
        case .rateLimited:
            ClaudeUsageMessage(
                symbol: "hourglass",
                title: "Too many requests",
                detail: "Claude asked to slow down. Usage will load again in a few minutes."
            )
        case .unavailable(let message):
            ClaudeUsageMessage(
                symbol: "wifi.exclamationmark",
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
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.gray)
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
        case .notSignedIn: "Not signed in"
        case .expired: "Sign-in expired"
        case .rateLimited: "Rate limited"
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
            .foregroundStyle(window.remainingTint ?? .white)
            .lineLimit(1)
            .fixedSize()
            .contentTransition(.numericText())
            .accessibilityLabel(Text("Claude 5-hour session: \(Int(window.remainingPercent.rounded()))% left"))
    }
}

/// The mascot and the session's remaining percentage, shown left of the music activity.
struct ClaudeClosedNotchBadge: View {
    let window: ClaudeUsageWindow
    @ObservedObject private var prompts = ClaudePromptCenter.shared

    var body: some View {
        HStack(spacing: 4) {
            ClawdView(activity: prompts.activity, size: CGSize(width: 18, height: 13))
            ClaudeClosedNotchPercent(window: window)
        }
    }
}
