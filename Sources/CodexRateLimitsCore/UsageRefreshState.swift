import Foundation

/// Retained values belong to one account context. Only the controller mutates them.
public struct UsageRefreshState: Sendable {
    public internal(set) var accountContext: CodexAccountContext?
    public internal(set) var weeklyWindow: RateLimitWindow?
    public internal(set) var quotaSampleAt: Date?
    public internal(set) var credits: CreditsSnapshot?
    public internal(set) var resetCredits: ResetCreditsSnapshot?
    public internal(set) var localUsage: LocalUsageSnapshot?
    public internal(set) var quotaForecast: QuotaForecast?
    public internal(set) var quotaMonitorError: String?

    public var weeklyRemaining: Int? { weeklyWindow?.remainingPercent }
    public var resetAvailableCount: Int? { resetCredits?.availableCount }

    public var matchingWeeklyQuotaCost: WeeklyQuotaCostEstimate? {
        guard let resetDate = weeklyWindow?.resetDate, let estimate = localUsage?.weeklyQuotaCost,
              let scope = accountContext?.scopeKey, estimate.accountScopeKey == scope else { return nil }
        return estimate.windowEndIso == ISO8601DateFormatter().string(from: resetDate) ? estimate : nil
    }
}
