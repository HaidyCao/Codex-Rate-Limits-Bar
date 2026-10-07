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
    var acknowledgeAlert: @Sendable (QuotaAlertEvent) -> String? = { _ in nil }
    var localHomeCount = 1

    static func live() -> Self {
        let monitor = QuotaMonitor()
        return Self(identity: { CodexBackend.currentRefreshIdentity() },
            official: { OfficialUsageUpdate(try CodexBackend.readRateLimits(cancellation: $0)) },
            local: { request, cancellation in
                try CodexBackend.readLocalTokenUsage(weeklyWindow: request.weeklyWindow, accountContext: request.accountContext,
                    rebuild: request.rebuild, quotaSampleAt: request.quotaSampleAt, cancellation: cancellation)
            },
            history: { monitor.update(window: $0, alertsEnabled: $1, accountContext: $2) },
            acknowledgeAlert: { monitor.acknowledge($0) })
    }

    static func live(selection: CodexHomeSelection) -> Self {
        let session = SelectedCodexSession(selection: selection)
        return Self(identity: { session.identity }, official: { try session.official($0) },
            local: { try session.local($0, cancellation: $1) },
            history: { session.monitor.update(window: $0, alertsEnabled: $1, accountContext: $2) },
            acknowledgeAlert: { session.monitor.acknowledge($0) }, localHomeCount: selection.localHomes.count)
    }
}

/// Each desktop selection owns a scanner with fixed roots and an account-scoped cache.
final class SelectedCodexSession: @unchecked Sendable {
    private let selection: CodexHomeSelection
    private let environment: [String: String]
    private let home: URL
    private let scanner: LocalUsageScanner
    let monitor: QuotaMonitor

    init(selection: CodexHomeSelection, environment: [String: String] = ProcessInfo.processInfo.environment,
         home: URL = FileManager.default.homeDirectoryForCurrentUser, monitor: QuotaMonitor = QuotaMonitor(),
         now: @escaping () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent) {
        self.selection = selection
        self.environment = selection.environment(overriding: environment)
        self.home = home
        self.monitor = monitor
        let selectedEnvironment = self.environment
        scanner = LocalUsageScanner(rootURLs: selection.localRoots, calendar: calendar, now: now,
            cacheFileURL: LocalUsagePaths.localUsageCacheURL(environment: selectedEnvironment, home: home),
            weeklyRootURLs: selection.weeklyRoots, allowMissingRoots: true,
            pricingProvider: { PricingCatalog.load(environment: selectedEnvironment) })
    }

    private var source: CodexAccountSource { CodexAccountSource(environment: environment, home: home) }
    var identity: String { CodexAccountContext.digest([selection.identity, source.refreshIdentity]) }

    func official(_ cancellation: RefreshCancellation) throws -> OfficialUsageUpdate {
        try RefreshWork.$cancellation.withValue(cancellation) {
            OfficialUsageUpdate(try OfficialUsageClient(sourceProvider: { self.source }).readAccountPayload(includeUsage: false))
        }
    }

    func local(_ request: LocalUsageRequest, cancellation: RefreshCancellation) throws -> LocalUsageSnapshot {
        let current = source
        let context = request.accountContext
        let matches = context?.accountKey != nil && context?.accountKey == current.identityKey
            && context?.codexHome == current.codexHome.path
        if context?.accountKey != nil && !matches { throw RuntimeError("Codex account changed before scanning; retry the request.") }
        return try scanner.snapshot(weeklyWindow: matches ? request.weeklyWindow : nil, accountContext: context,
            invalidateWeeklyObservation: context != nil && !matches, rebuild: request.rebuild,
            quotaSampleAt: matches ? request.quotaSampleAt : nil, cancellation: cancellation,
            validateCommit: { current.matches(self.source) })
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
