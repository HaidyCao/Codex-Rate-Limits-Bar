import Foundation

enum OfficialResponseNormalizer {
    static func normalizeRateLimitResponse(_ response: [String: Any]) -> RateLimitPayload {
        let rateLimits = normalizeSnapshot(dictionaryValue(response["rateLimits"]))
        var byLimitId: [String: RateLimitSnapshot] = [:]
        for (limitId, value) in dictionaryValue(response["rateLimitsByLimitId"]) ?? [:] {
            byLimitId[limitId] = normalizeSnapshot(dictionaryValue(value))
        }
        let weekly = (byLimitId["codex"] ?? rateLimits)?.weeklyWindow
        let display = RateLimitDisplay(
            primaryLabel: weekly.map { "W \($0.remainingPercent)%" } ?? "W --",
            secondaryLabel: nil,
            primaryRemainingPercent: weekly?.remainingPercent,
            secondaryRemainingPercent: nil
        )
        return RateLimitPayload(
            fetchedAtIso: isoNow(),
            rateLimits: rateLimits,
            rateLimitsByLimitId: byLimitId.isEmpty ? nil : byLimitId,
            display: display,
            resetCredits: nil,
            localUsage: nil,
            rateLimitError: nil,
            localUsageError: nil,
            usage: nil
        )
    }

    private static func normalizeSnapshot(_ snapshot: [String: Any]?) -> RateLimitSnapshot? {
        guard let snapshot else { return nil }
        return RateLimitSnapshot(
            limitId: stringValue(snapshot["limitId"]),
            limitName: stringValue(snapshot["limitName"]),
            planType: stringValue(snapshot["planType"]),
            rateLimitReachedType: stringValue(snapshot["rateLimitReachedType"]),
            primary: normalizeWindow(dictionaryValue(snapshot["primary"])),
            secondary: normalizeWindow(dictionaryValue(snapshot["secondary"])),
            credits: normalizeCredits(dictionaryValue(snapshot["credits"])),
            individualLimit: snapshot.keys.contains("individualLimit") ? JSONValue.from(snapshot["individualLimit"]) : nil
        )
    }

    private static func normalizeWindow(_ window: [String: Any]?) -> RateLimitWindow? {
        guard let window else { return nil }
        let usedPercent = intValue(window["usedPercent"]) ?? 0
        let resetsAt = intValue(window["resetsAt"])
        return RateLimitWindow(
            usedPercent: usedPercent,
            remainingPercent: max(0, 100 - usedPercent),
            windowDurationMins: intValue(window["windowDurationMins"]),
            resetsAt: resetsAt,
            resetsAtIso: isoFromEpochSeconds(resetsAt)
        )
    }

    private static func normalizeCredits(_ credits: [String: Any]?) -> CreditsSnapshot? {
        guard let credits else { return nil }
        return CreditsSnapshot(
            hasCredits: boolValue(credits["hasCredits"]),
            unlimited: boolValue(credits["unlimited"]),
            balance: stringValue(credits["balance"])
        )
    }

    static func normalizeResetCreditsResponse(_ response: [String: Any]) -> ResetCreditsSnapshot {
        var credits = arrayValue(response["credits"])
            .compactMap { normalizeResetCredit(dictionaryValue($0)) }
        credits.sort { resetCreditSortKey($0) < resetCreditSortKey($1) }

        let fallbackAvailableCount = credits.filter { $0.status == "available" }.count
        let availableCount = intValue(response["availableCount"] ?? response["available_count"])
            ?? (response["credits"] is [Any] ? fallbackAvailableCount : nil)
        let firstTypeLabel = credits.first?.typeLabel ?? AppText.resetCreditsCategory
        let visibleSource = credits.contains { $0.status == "available" }
            ? credits.filter { $0.status == "available" }
            : credits
        var detailLabels = Array(visibleSource.prefix(4)).enumerated().map { index, credit in
            AppText.resetCreditDetail(
                index: index + 1,
                status: credit.statusLabel,
                expiresAt: credit.expiresAtShortLabel
            )
        }
        if detailLabels.isEmpty, (availableCount ?? 0) > 0 {
            detailLabels = [AppText.resetCreditDetailsUnavailable]
        }

        return ResetCreditsSnapshot(
            fetchedAtIso: isoNow(),
            availableCount: availableCount,
            credits: credits,
            error: nil,
            display: ResetCreditsDisplay(
                summaryLabel: AppText.availableCount(availableCount),
                categoryLabel: firstTypeLabel,
                detailLabels: detailLabels
            ),
            detailsAvailable: response["credits"] is [Any]
        )
    }

    private static func normalizeResetCredit(_ credit: [String: Any]?) -> ResetCreditItem? {
        guard let credit else { return nil }
        let resetType = stringValue(credit["resetType"] ?? credit["reset_type"]) ?? stringValue(credit["type"]) ?? "unknown"
        let status = stringValue(credit["status"])
        let createdAtIso = isoString(credit["grantedAt"] ?? credit["created_at"] ?? credit["granted_at"])
        let expiresAtIso = isoString(credit["expiresAt"] ?? credit["expires_at"])
        return ResetCreditItem(
            id: stringValue(credit["id"]),
            resetType: resetType,
            typeLabel: resetCreditTypeLabel(resetType),
            status: status,
            statusLabel: resetCreditStatusLabel(status),
            createdAtIso: createdAtIso,
            expiresAtIso: expiresAtIso,
            createdAtLabel: AppText.resetDateTime(createdAtIso, short: false),
            expiresAtLabel: AppText.resetDateTime(expiresAtIso, short: false),
            createdAtShortLabel: AppText.resetDateTime(createdAtIso, short: true),
            expiresAtShortLabel: AppText.resetDateTime(expiresAtIso, short: true)
        )
    }

    static func emptyRateLimitSnapshot(_ error: Error) -> RateLimitPayload {
        RateLimitPayload(
            fetchedAtIso: isoNow(),
            rateLimits: nil,
            rateLimitsByLimitId: nil,
            display: RateLimitDisplay(
                primaryLabel: "W --",
                secondaryLabel: nil,
                primaryRemainingPercent: nil,
                secondaryRemainingPercent: nil
            ),
            resetCredits: nil,
            localUsage: nil,
            rateLimitError: errorMessage(error),
            localUsageError: nil,
            usage: nil
        )
    }

    static func emptyResetCreditsSnapshot(_ error: Error) -> ResetCreditsSnapshot {
        var snapshot = ResetCreditsSnapshot(
            fetchedAtIso: isoNow(),
            availableCount: nil,
            credits: [],
            error: errorMessage(error),
            display: ResetCreditsDisplay(
                summaryLabel: AppText.availableCount(nil),
                categoryLabel: AppText.resetCreditsCategory,
                detailLabels: [AppText.resetCreditsUnavailable]
            )
        )
        snapshot.freshness = RefreshCoordinator.oneShot([.resetCredits: RefreshOutcome(.failed, error: errorMessage(error))], attemptedAt: Date(), now: Date()).resetCredits
        return snapshot
    }

    private static func isoString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            let seconds = raw > 10_000_000_000 ? raw / 1000 : raw
            return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
        }
        guard let string = stringValue(value), !string.isEmpty else { return nil }
        return parseIsoDate(string).map { ISO8601DateFormatter().string(from: $0) }
    }

    private static func resetCreditTypeLabel(_ value: String?) -> String {
        AppText.resetCreditTypeLabel(value)
    }

    private static func resetCreditStatusLabel(_ value: String?) -> String {
        AppText.resetCreditStatusLabel(value)
    }

    private static func resetCreditSortKey(_ credit: ResetCreditItem) -> String {
        if credit.status == "available" {
            return "0-\(credit.expiresAtIso ?? "")-\(credit.createdAtIso ?? "")"
        }
        return "1-\(credit.expiresAtIso ?? "")-\(credit.createdAtIso ?? "")"
    }
}
