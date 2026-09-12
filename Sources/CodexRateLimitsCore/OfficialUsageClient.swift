import Foundation

/// Owns account-consistent official reads; transports and account source are replaceable.
struct OfficialUsageClient {
    private static let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    private let sourceProvider: () -> CodexAccountSource
    private let call: ([String], String) throws -> [String: Any]
    private let fetchReset: (URLRequest) throws -> Data

    init(sourceProvider: @escaping () -> CodexAccountSource = { CodexAccountSource() },
         call: @escaping ([String], String) throws -> [String: Any] = { try OfficialUsageTransport.callCodexAppServer(methods: $0, codexHome: $1) },
         fetchReset: @escaping (URLRequest) throws -> Data = OfficialUsageTransport.fetchData) {
        self.sourceProvider = sourceProvider
        self.call = call
        self.fetchReset = fetchReset
    }

    func readAccountPayload(includeUsage: Bool) throws -> RateLimitPayload {
        let attemptedAt = Date()
        try RefreshWork.check()
        let before = sourceProvider()
        let methods = ["account/read", "account/rateLimits/read"] + (includeUsage ? ["account/usage/read"] : [])
        let results = try call(methods, before.codexHome.path)
        let after = sourceProvider()
        guard before.matches(after) else { throw RuntimeError("Codex account changed while refreshing; retry the request.") }
        guard let response = dictionaryValue(results["account/rateLimits/read"]) else {
            throw RuntimeError("account/rateLimits/read returned invalid payload")
        }
        let account = dictionaryValue(results["account/read"]).flatMap { dictionaryValue($0["account"]) }
        let normalized = OfficialResponseNormalizer.normalizeRateLimitResponse(response)
        let context = after.context(account: account, limitID: normalized.selectedRateLimit?.limitId ?? "codex")
        let resetCredits = Self.resolveResetCredits(response: response, source: after, context: context, fetch: fetchReset)
        try RefreshWork.check()
        guard after.matches(sourceProvider()) else { throw RuntimeError("Codex account changed while refreshing; retry the request.") }
        var payload = RateLimitPayload(
            fetchedAtIso: normalized.fetchedAtIso, rateLimits: normalized.rateLimits,
            rateLimitsByLimitId: normalized.rateLimitsByLimitId, display: normalized.display,
            resetCredits: resetCredits, localUsage: nil, rateLimitError: nil, localUsageError: nil,
            usage: includeUsage ? JSONValue.from(results["account/usage/read"]) : nil,
            accountContext: context
        )
        payload.refresh = RefreshCoordinator.oneShot(RefreshOutcome.official(payload), attemptedAt: attemptedAt, now: Date())
        return payload
    }

    static func resolveResetCredits(
        response: [String: Any], source: CodexAccountSource, context: CodexAccountContext,
        fetch: (URLRequest) throws -> Data
    ) -> ResetCreditsSnapshot {
        let attemptedAt = Date()
        var snapshot: ResetCreditsSnapshot
        if let official = dictionaryValue(response["rateLimitResetCredits"]) {
            snapshot = OfficialResponseNormalizer.normalizeResetCreditsResponse(official)
        } else {
            do {
                guard let identity = source.identityKey, identity == context.accountKey,
                      source.codexHome.path == context.codexHome, source.authFile.path == context.authenticationSource,
                      let accessToken = source.tokens["access_token"] as? String, !accessToken.isEmpty else {
                    throw RuntimeError("Reset credits unavailable: the active account's file credentials could not be verified.")
                }
                var request = URLRequest(url: Self.resetCreditsURL)
                request.httpMethod = "GET"
                request.timeoutInterval = 12
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
                request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
                request.setValue(source.tokens["account_id"] as? String, forHTTPHeaderField: "ChatGPT-Account-ID")
                let data = try fetch(request)
                let object = try JSONSerialization.jsonObject(with: data)
                snapshot = OfficialResponseNormalizer.normalizeResetCreditsResponse(dictionaryValue(object) ?? [:])
            } catch {
                snapshot = OfficialResponseNormalizer.emptyResetCreditsSnapshot(error)
            }
        }
        snapshot.accountContext = context
        let phase: RefreshPhase = snapshot.error != nil ? .failed : snapshot.availableCount == nil ? .unavailable
            : snapshot.detailsAvailable == false ? .partial : .success
        snapshot.freshness = RefreshCoordinator.oneShot([.resetCredits: RefreshOutcome(phase,
            at: snapshot.error == nil && snapshot.availableCount != nil ? parseIsoDate(snapshot.fetchedAtIso) : nil,
            error: snapshot.error ?? (snapshot.availableCount == nil ? "Reset-credit count was not returned." : nil))], attemptedAt: attemptedAt, now: Date()).resetCredits
        return snapshot
    }

}
