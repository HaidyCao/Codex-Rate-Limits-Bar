import Foundation

struct LocalUsageCacheDocument: Codable {
    static let currentVersion = 4

    var version = currentVersion
    let cache: LocalUsageScanCache
}

struct LocalUsageScanCache: Codable {
    var source: String
    var rootPaths: [String]?
    let localDate: String
    let timeZone: String
    var dayStart: Date
    var dayEnd: Date
    var files: [String: LocalUsageFileState] = [:]
    var weeklyCostObservation: LocalUsageWeeklyCostObservation?
    var pricing: UsagePricingMetadata?

    /// Another process may save while our last write is pending. Adopt its file
    /// cursors, then retain observations only for the exact same baseline.
    mutating func retainPendingHistory(from pending: Self) {
        guard source == pending.source, timeZone == pending.timeZone,
              let saved = weeklyCostObservation, let unsaved = pending.weeklyCostObservation,
              saved.windowID == unsaved.windowID, saved.accountScopeKey == unsaved.accountScopeKey,
              saved.rootPaths == unsaved.rootPaths, saved.startedAt == unsaved.startedAt,
              saved.timelineStartedAt == unsaved.timelineStartedAt,
              saved.baselineUsedPercent == unsaved.baselineUsedPercent else { return }
        var samples = Dictionary((unsaved.history?.samples ?? []).map { ($0.timestamp, $0) },
                                 uniquingKeysWith: { _, last in last })
        for sample in saved.history?.samples ?? [] { samples[sample.timestamp] = sample }
        var history = WeeklyQuotaHistory(restartReason: saved.history?.restartReason)
        for sample in samples.values.sorted(by: { $0.timestamp < $1.timestamp }) {
            history.observe(usedPercent: sample.usedPercent, at: sample.timestamp, now: sample.timestamp)
        }
        weeklyCostObservation?.history = history
    }
}

struct LocalUsageWeeklyCostObservation: Codable {
    let windowID: QuotaWindowID
    let startedAt: Date
    let baselineUsedPercent: Int
    var rootPaths: [String]?
    var accountScopeKey: String?
    var timelineStartedAt: Date?
    var history: WeeklyQuotaHistory?
}

struct LocalUsageFileState: Codable {
    var offset: UInt64 = 0
    var size: UInt64 = 0
    var modifiedAt: Date?
    var fileStamp: UsageFileStamp?
    var prefixDigest: String?
    var copyMembers: [String]?
    var copyDay: String?
    var copyAlgorithmVersion: Int?
    var copyHistoryConflict: Bool?
    var weeklyCopyHistoryConflict: Bool?
    var latestUsageAt: Date?
    var hasUsageBounds: Bool?
    var diagnostics: UsageFileDiagnostics?
    var pendingData = Data()
    var isSkippingOversizedLine: Bool?
    var previousTotalUsage: TokenUsage?
    var previousObservedTotalUsage: TokenUsage?
    var previousUsageSessionId: String?
    var primarySessionId: String?
    var activeSessionId: String?
    var currentModel: String?
    var currentServiceTier: String?
    var totals = TokenUsage()
    var dailyCost: TokenCostAccumulator?
    var weeklyCost: TokenCostAccumulator?
    var weeklyTimeline: [Int: WeeklyCostBucket]?
    var eventCount = 0
    var duplicateEventCount = 0
    var importedEventCount = 0
    var regressionEventCount = 0
    var parseErrorCount = 0
    var lastEventAtIso: String?

    var requiresCostRebuild: Bool {
        dailyCost?.requiresRepricing == true || weeklyCost?.requiresRepricing == true
    }

    var requiresBlankLineReplay: Bool {
        parseErrorCount > 0 && diagnostics?.blankLinesChecked != true
    }

    func resetForNewDay() -> LocalUsageFileState {
        var state = self
        state.totals = TokenUsage()
        state.eventCount = 0
        state.duplicateEventCount = 0
        state.importedEventCount = 0
        state.regressionEventCount = 0
        state.diagnostics?.todayUsageEvents = 0
        state.lastEventAtIso = nil
        state.dailyCost = nil
        return state
    }
}
