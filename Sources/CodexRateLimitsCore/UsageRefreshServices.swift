import Foundation

/// Work stays off the main actor. Tests can hold and release each lane explicitly.
protocol RefreshExecuting: Sendable {
    func execute(_ lane: RefreshLane, work: @escaping @Sendable () -> Void)
}

struct DispatchRefreshExecutor: RefreshExecuting {
    private let official = DispatchQueue(label: "local.codex.rate-limits-bar.rate-limits", qos: .utility, autoreleaseFrequency: .workItem)
    private let local = DispatchQueue(label: "local.codex.rate-limits-bar.local-usage", qos: .utility, autoreleaseFrequency: .workItem)

    func execute(_ lane: RefreshLane, work: @escaping @Sendable () -> Void) {
        (lane == .official ? official : local).async(execute: work)
    }
}

struct LocalUsageRequest: Sendable {
    let weeklyWindow: RateLimitWindow?
    let accountContext: CodexAccountContext?
    let quotaSampleAt: Date?
    let rebuild: Bool
}

struct UsageRefreshServices: Sendable {
    let identity: @Sendable () -> String
    let official: @Sendable (RefreshCancellation) throws -> OfficialUsageUpdate
    let local: @Sendable (LocalUsageRequest, RefreshCancellation) throws -> LocalUsageSnapshot
    let history: @Sendable (RateLimitWindow, Bool, CodexAccountContext?) -> QuotaMonitorSnapshot

    static func live() -> Self {
        let monitor = QuotaMonitor()
        return Self(identity: { CodexBackend.currentRefreshIdentity() },
            official: { OfficialUsageUpdate(try CodexBackend.readRateLimits(cancellation: $0)) },
            local: { request, cancellation in
                try CodexBackend.readLocalTokenUsage(weeklyWindow: request.weeklyWindow, accountContext: request.accountContext,
                    rebuild: request.rebuild, quotaSampleAt: request.quotaSampleAt, cancellation: cancellation)
            },
            history: { monitor.update(window: $0, alertsEnabled: $1, accountContext: $2) })
    }
}

struct OfficialUsageUpdate: Sendable {
    let weekly: RateLimitWindow?
    let error: String?
    let credits: CreditsSnapshot?
    let accountContext: CodexAccountContext?
    let resetCredits: ResetCreditsSnapshot?
    let sampledAt: Date?
    let outcomes: [RefreshSource: RefreshOutcome]

    init(_ payload: RateLimitPayload) {
        weekly = payload.selectedRateLimit?.weeklyWindow
        error = payload.rateLimitError
        credits = payload.selectedRateLimit?.credits
        accountContext = payload.accountContext
        resetCredits = payload.resetCredits
        sampledAt = RefreshOutcome.date(payload.fetchedAtIso)
        outcomes = RefreshOutcome.official(payload)
    }
}
