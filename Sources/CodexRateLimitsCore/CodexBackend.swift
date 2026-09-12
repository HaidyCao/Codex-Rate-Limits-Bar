import Foundation

public enum CodexBackend {
    private static let localUsageScanner = LocalUsageScanner()

    public static func currentRefreshIdentity() -> String { CodexAccountSource().refreshIdentity }

    public static func readRateLimits(cancellation: RefreshCancellation? = nil) throws -> RateLimitPayload {
        try RefreshWork.$cancellation.withValue(cancellation) { try OfficialUsageClient().readAccountPayload(includeUsage: false) }
    }

    public static func readTokenUsage() throws -> AccountUsageSnapshot {
        let results = try OfficialUsageTransport.callCodexAppServer(methods: ["account/usage/read"])
        return AccountUsageSnapshot(fetchedAtIso: isoNow(), usage: JSONValue.from(results["account/usage/read"]))
    }

    public static func readCombined() throws -> RateLimitPayload {
        try OfficialUsageClient().readAccountPayload(includeUsage: true)
    }

    public static func readResetCredits(soft: Bool = false) throws -> ResetCreditsSnapshot {
        do {
            guard let snapshot = try readRateLimits().resetCredits else { throw RuntimeError("Reset credits unavailable") }
            if let error = snapshot.error, !soft { throw RuntimeError(error) }
            return snapshot
        } catch {
            if soft { return OfficialResponseNormalizer.emptyResetCreditsSnapshot(error) }
            throw error
        }
    }

    public static func readStatus() -> RateLimitPayload {
        let attemptedAt = Date()
        let ratePayload: RateLimitPayload
        do {
            ratePayload = try readRateLimits()
        } catch {
            ratePayload = OfficialResponseNormalizer.emptyRateLimitSnapshot(error)
        }

        let resetCredits = ratePayload.resetCredits ?? OfficialResponseNormalizer.emptyResetCreditsSnapshot(RuntimeError("reset credits unavailable"))
        let localAttemptedAt = Date()
        let localUsage: LocalUsageSnapshot
        let localUsageError: String?
        do {
            localUsage = try readLocalTokenUsage(weeklyWindow: ratePayload.selectedRateLimit?.weeklyWindow, accountContext: ratePayload.accountContext,
                                                quotaSampleAt: parseIsoDate(ratePayload.fetchedAtIso))
            localUsageError = localUsage.error
        } catch {
            localUsage = LocalUsageFormatting.emptyLocalUsageSnapshot(error)
            localUsageError = errorMessage(error)
        }

        var payload = RateLimitPayload(
            fetchedAtIso: ratePayload.fetchedAtIso,
            rateLimits: ratePayload.rateLimits,
            rateLimitsByLimitId: ratePayload.rateLimitsByLimitId,
            display: ratePayload.display,
            resetCredits: resetCredits,
            localUsage: localUsage,
            rateLimitError: ratePayload.rateLimitError,
            localUsageError: localUsageError,
            usage: nil,
            accountContext: ratePayload.accountContext
        )
        var outcomes = RefreshOutcome.official(ratePayload)
        outcomes[.localUsage] = RefreshOutcome.local(localUsage)
        let official = RefreshCoordinator.oneShot(outcomes, attemptedAt: attemptedAt, now: Date())
        let local = RefreshCoordinator.oneShot([.localUsage: RefreshOutcome.local(localUsage)], attemptedAt: localAttemptedAt, now: Date())
        payload.refresh = RefreshSnapshot(quota: official.quota, credits: official.credits,
            resetCredits: official.resetCredits, localUsage: local.localUsage, networkAvailable: nil)
        return payload
    }

    public static func readLocalTokenUsage(weeklyWindow: RateLimitWindow? = nil,
                                           accountContext: CodexAccountContext? = nil,
                                           rebuild: Bool = false, quotaSampleAt: Date? = nil,
                                           cancellation: RefreshCancellation? = nil) throws -> LocalUsageSnapshot {
        let current = CodexAccountSource()
        let matches = accountContext?.accountKey != nil && accountContext?.accountKey == current.identityKey
            && accountContext?.codexHome == current.codexHome.path
        if accountContext?.accountKey != nil && !matches { throw RuntimeError("Codex account changed before scanning; retry the request.") }
        return try localUsageScanner.snapshot(weeklyWindow: matches ? weeklyWindow : nil, accountContext: accountContext,
            invalidateWeeklyObservation: accountContext != nil && !matches, rebuild: rebuild,
            quotaSampleAt: matches ? quotaSampleAt : nil, cancellation: cancellation,
            validateCommit: { current.matches(CodexAccountSource()) })
    }

}
