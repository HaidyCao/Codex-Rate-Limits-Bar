import Foundation

enum LocalUsageFormatting {
    static func localDateString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func formatCacheHitPercent(_ percent: Double?) -> String {
        guard let percent else { return "--" }
        return String(format: "%.1f%%", percent)
    }

    static func emptyLocalUsageSnapshot(_ error: Error) -> LocalUsageSnapshot {
        let now = Date()
        let source = LocalUsagePaths.localUsageSourceDescription(rootURLs: LocalUsagePaths.localUsageRootURLs())
        let diagnostics = UsageScanDiagnostics.make(roots: [], filesDiscovered: 0, filesVerified: 0,
            validRecords: 0, usageEvents: 0, issues: [UsageScanIssue(kind: .cacheUnavailable, path: nil, count: 1,
                                                                 message: errorMessage(error))])
        var snapshot = LocalUsageSnapshot(
            fetchedAtIso: ISO8601DateFormatter().string(from: now),
            source: source,
            timezone: TimeZone.current.identifier,
            localDate: localDateString(now, timeZone: .current),
            inputTokens: 0,
            cachedInputTokens: 0,
            cacheWriteInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            totalTokens: 0,
            cacheHitPercent: nil,
            eventCount: 0,
            duplicateEventCount: 0,
            importedEventCount: 0,
            regressionEventCount: 0,
            filesScanned: 0,
            filesWithEvents: 0,
            parseErrorCount: 0,
            error: errorMessage(error),
            topFiles: [],
            todayCost: nil,
            weeklyQuotaCost: nil,
            display: LocalUsageDisplay(
                consumptionLabel: AppText.consumption(nil),
                cacheHitLabel: AppText.cacheHit(nil),
                estimatedCostLabel: nil,
                weeklyQuotaCostLabel: nil,
                scanStatusLabel: AppText.scanStatus(diagnostics)
            ),
            diagnostics: diagnostics
        )
        snapshot.freshness = RefreshCoordinator.oneShot([.localUsage: RefreshOutcome.local(snapshot)], attemptedAt: now, now: Date()).localUsage
        return snapshot
    }

}
