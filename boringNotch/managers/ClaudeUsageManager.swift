//
//  ClaudeUsageManager.swift
//  boringNotch
//
//  Claude plan usage for the Claude tab. The XPC helper reads Claude Code's token and calls the
//  usage API (see ClaudeUsageFetcher); this side only decodes the result and throttles requests.
//

import Defaults
import Foundation

struct ClaudeUsageWindow: Identifiable, Equatable {
    enum Kind: CaseIterable {
        case session, weekly, sonnet, opus
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
    case notSignedIn
    /// Claude Code refreshes its own token; the notch never does, because that would sign Claude Code out.
    case expired
    case rateLimited
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
    static let refreshInterval: TimeInterval = 60
    /// Pace for keeping the closed-notch session figure current while the tab is hidden.
    private static let backgroundRefreshInterval: TimeInterval = 5 * 60
    /// Floor for the manual refresh button.
    private static let manualRefreshInterval: TimeInterval = 10
    private static let defaultRateLimitBackoff: TimeInterval = 300

    private var lastAttempt: Date?
    private var blockedUntil: Date?
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
        if let blockedUntil, now < blockedUntil { return }
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
            guard let payload = envelope.usage else {
                problem = .unavailable(String(localized: "Unexpected response"))
                return
            }
            usage = ClaudeUsage(plan: envelope.plan, windows: payload.windows)
            problem = nil
            lastUpdated = Date()
        case "notSignedIn":
            usage = nil
            problem = .notSignedIn
        case "expired", "unauthorized":
            problem = .expired
        case "rateLimited":
            blockedUntil = Date().addingTimeInterval(envelope.retryAfter ?? Self.defaultRateLimitBackoff)
            problem = .rateLimited
        default:
            problem = .unavailable(envelope.message ?? String(localized: "Request failed"))
        }
    }

    // MARK: - Helper response

    private struct Envelope: Decodable {
        let status: String
        let plan: String?
        let retryAfter: TimeInterval?
        let message: String?
        let usage: UsagePayload?
    }

    private struct UsagePayload: Decodable {
        let windows: [ClaudeUsageWindow]

        private enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDaySonnet = "seven_day_sonnet"
            case sevenDayOpus = "seven_day_opus"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let keys: [(CodingKeys, ClaudeUsageWindow.Kind)] = [
                (.fiveHour, .session), (.sevenDay, .weekly), (.sevenDaySonnet, .sonnet), (.sevenDayOpus, .opus)
            ]
            // A window the API leaves out, sends as null, or reshapes is skipped rather than failing the rest.
            windows = keys.compactMap { key, kind in
                guard let window = try? container.decodeIfPresent(WindowPayload.self, forKey: key),
                      let utilization = window.utilization
                else { return nil }
                return ClaudeUsageWindow(
                    kind: kind,
                    usedPercent: min(max(utilization, 0), 100),
                    resetsAt: window.resetsAt.flatMap(Self.parseDate)
                )
            }
        }

        private struct WindowPayload: Decodable {
            let utilization: Double?
            let resetsAt: String?

            private enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }
        }

        /// The API sends microsecond fractions, which ISO8601DateFormatter does not parse reliably.
        private static func parseDate(_ value: String) -> Date? {
            let trimmed = value.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
            return ISO8601DateFormatter().date(from: trimmed)
        }
    }
}
