//
//  ClaudeUsageManager.swift
//  boringNotch
//
//  Claude plan usage for the Claude tab. The XPC helper asks Claude Code for its `/usage` text
//  (see ClaudeUsageFetcher); this side parses it and paces the requests.
//

import Defaults
import Foundation

struct ClaudeUsageWindow: Identifiable, Equatable {
    enum Kind: Hashable {
        case session, weekly
        /// A weekly limit for one model family, named as Claude Code names it.
        case model(String)
    }

    let kind: Kind
    /// 0–100
    let usedPercent: Double
    let resetsAt: Date?

    var id: Kind { kind }
}

struct ClaudeUsage: Equatable {
    let plan: String?
    let windows: [ClaudeUsageWindow]
}

enum ClaudeUsageProblem: Equatable {
    case notInstalled
    case notSignedIn
    case unavailable(String)
}

@MainActor
final class ClaudeUsageManager: ObservableObject {
    static let shared = ClaudeUsageManager()

    /// The last successful reading, kept while later requests fail.
    @Published private(set) var usage: ClaudeUsage?
    @Published private(set) var problem: ClaudeUsageProblem?
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?

    /// The tab polls at this pace while it is visible; reopening the notch does not fetch sooner.
    /// Each reading starts Claude Code for a couple of seconds, so it stays unhurried.
    static let refreshInterval: TimeInterval = 60
    /// Pace for keeping the closed-notch session figure current while the tab is hidden.
    private static let backgroundRefreshInterval: TimeInterval = 5 * 60
    /// Floor for the manual refresh button.
    private static let manualRefreshInterval: TimeInterval = 10

    private var lastAttempt: Date?
    private var backgroundRefreshTask: Task<Void, Never>?

    private init() {
        Task { [weak self] in
            for await enabled in Defaults.updates(.showClaudeInClosedNotch) {
                self?.setBackgroundRefresh(enabled)
            }
        }
    }

    /// The 5-hour session, which the closed notch shows.
    var session: ClaudeUsageWindow? {
        usage?.windows.first { $0.kind == .session }
    }

    private func setBackgroundRefresh(_ enabled: Bool) {
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = nil
        guard enabled else { return }
        backgroundRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(Self.backgroundRefreshInterval))
            }
        }
    }

    func refresh(manual: Bool = false) async {
        let now = Date()
        guard !isLoading else { return }
        let interval = manual ? Self.manualRefreshInterval : Self.refreshInterval
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < interval { return }

        lastAttempt = now
        isLoading = true
        defer { isLoading = false }

        guard let data = await XPCHelperClient.shared.fetchClaudeUsage() else {
            problem = .unavailable(String(localized: "Helper unavailable"))
            return
        }
        apply(data)
    }

    private func apply(_ data: Data) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            problem = .unavailable(String(localized: "Unexpected response"))
            return
        }

        switch envelope.status {
        case "ok":
            let windows = Self.parseUsage(envelope.output ?? "")
            guard !windows.isEmpty else {
                problem = .unavailable(String(localized: "Claude Code did not report any usage"))
                return
            }
            usage = ClaudeUsage(plan: envelope.plan, windows: windows)
            problem = nil
            lastUpdated = Date()
        case "notInstalled":
            usage = nil
            problem = .notInstalled
        case "notSignedIn":
            usage = nil
            problem = .notSignedIn
        default:
            problem = .unavailable(envelope.message ?? String(localized: "Request failed"))
        }
    }

    private struct Envelope: Decodable {
        let status: String
        let plan: String?
        let message: String?
        let output: String?
    }

    // MARK: - Parsing `/usage`

    /// Reads lines such as `Current session: 54% used · resets Oct 12 at 6:09pm (Asia/Saigon)` and
    /// `Current week (Fable): 24% used · resets …`, up to the breakdown that follows them.
    static func parseUsage(_ output: String, now: Date = Date()) -> [ClaudeUsageWindow] {
        let pattern = #"^Current (session|week)(?: \(([^)]+)\))?:\s*([0-9]+(?:\.[0-9]+)?)%\s*(used|left)(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }

        var windows: [ClaudeUsageWindow] = []
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("what") && !windows.isEmpty { break }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range) else { continue }
            func group(_ index: Int) -> String? {
                Range(match.range(at: index), in: line).map { String(line[$0]) }
            }
            guard let period = group(1)?.lowercased(), let value = group(3).flatMap(Double.init) else { continue }

            let kind: ClaudeUsageWindow.Kind
            if period == "session" {
                kind = .session
            } else if let model = group(2), model.lowercased() != "all models" {
                kind = .model(model)
            } else {
                kind = .weekly
            }
            guard !windows.contains(where: { $0.kind == kind }) else { continue }

            let used = group(4)?.lowercased() == "left" ? 100 - value : value
            windows.append(ClaudeUsageWindow(
                kind: kind,
                usedPercent: min(max(used, 0), 100),
                resetsAt: group(5).flatMap { parseReset($0, now: now) }
            ))
        }
        return windows
    }

    /// `· resets Oct 12 at 6:09pm (Asia/Saigon)`, or a time alone for later today.
    private static func parseReset(_ text: String, now: Date) -> Date? {
        guard let resets = text.range(of: "resets", options: .caseInsensitive) else { return nil }
        var rest = text[resets.upperBound...].trimmingCharacters(in: .whitespaces)

        var timeZone = TimeZone.current
        if let open = rest.lastIndex(of: "("), let close = rest.lastIndex(of: ")"), open < close {
            let name = String(rest[rest.index(after: open)..<close])
            timeZone = TimeZone(identifier: name) ?? timeZone
            rest = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
        }
        rest = rest.replacingOccurrences(of: " at ", with: " ").uppercased()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        for format in ["MMM d h:mma", "MMM d ha", "MMM d H:mm"] {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: rest) else { continue }
            // No year is given: take this year's date, or next year's when that is long past.
            var parts = calendar.dateComponents([.month, .day, .hour, .minute], from: parsed)
            parts.year = calendar.component(.year, from: now)
            guard var date = calendar.date(from: parts) else { continue }
            if date < now.addingTimeInterval(-2 * 24 * 60 * 60) {
                date = calendar.date(byAdding: .year, value: 1, to: date) ?? date
            }
            return date
        }
        for format in ["h:mma", "ha", "H:mm"] {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: rest) else { continue }
            let time = calendar.dateComponents([.hour, .minute], from: parsed)
            return calendar.nextDate(after: now, matching: time, matchingPolicy: .nextTime)
        }
        return nil
    }
}
