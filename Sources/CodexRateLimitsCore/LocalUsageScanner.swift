import Darwin
import CryptoKit
import Foundation

final class LocalUsageScanner: @unchecked Sendable {
    private static let readChunkSize = 1 * 1_024 * 1_024
    private static let maxBufferedLineSize = 8 * 1_024 * 1_024
    private static let retainedHistoryDays = 8

    private let lock = NSLock()
    private let timestampParser = LocalUsageLog.TimestampParser()
    private let rootURLsProvider: () -> [URL]
    private let weeklyRootURLsProvider: () -> [URL]
    private let nowProvider: () -> Date
    private let calendarProvider: () -> Calendar
    private var cacheStore: LocalUsageCacheStore
    private var cache: LocalUsageScanCache?
    private var readBuffer = Data()
    private var copyLedger: UsageCopyLedger?
    private var scanIssues: [UsageScanIssue] = []
    private var rootStatuses: [UsageRootStatus] = []
    private var timelineStartedAt: Date?
    private var pricingProvider: () -> PricingSnapshot = { PricingCatalog.builtin }
    private let allowMissingRoots: Bool

    init() {
        pricingProvider = { PricingCatalog.load() }
        allowMissingRoots = ProcessInfo.processInfo.environment["CODEX_SESSIONS_DIR"]?.isEmpty != false
        rootURLsProvider = { LocalUsagePaths.localUsageRootURLs() }
        weeklyRootURLsProvider = { LocalUsagePaths.weeklyUsageRootURLs() }
        nowProvider = Date.init
        calendarProvider = { .current }
        cacheStore = LocalUsageCacheStore(fileURL: LocalUsagePaths.localUsageCacheURL())
    }

    init(rootURLs: [URL], calendar: Calendar, now: @escaping () -> Date, cacheFileURL: URL? = nil,
         weeklyRootURLs: [URL]? = nil, allowMissingRoots: Bool = false,
         pricingProvider: @escaping () -> PricingSnapshot = { PricingCatalog.builtin }) {
        self.allowMissingRoots = allowMissingRoots
        rootURLsProvider = { rootURLs }
        weeklyRootURLsProvider = { weeklyRootURLs ?? rootURLs }
        nowProvider = now
        calendarProvider = { calendar }
        cacheStore = LocalUsageCacheStore(fileURL: cacheFileURL)
        self.pricingProvider = pricingProvider
    }

    init(
        rootURLs: [URL],
        calendarProvider: @escaping () -> Calendar,
        now: @escaping () -> Date,
        cacheFileURL: URL? = nil
    ) {
        allowMissingRoots = false
        rootURLsProvider = { rootURLs }
        weeklyRootURLsProvider = { rootURLs }
        nowProvider = now
        self.calendarProvider = calendarProvider
        cacheStore = LocalUsageCacheStore(fileURL: cacheFileURL)
    }

    func snapshot(weeklyWindow: RateLimitWindow? = nil, accountContext: CodexAccountContext? = nil,
                  invalidateWeeklyObservation: Bool = false, rebuild: Bool = false, quotaSampleAt: Date? = nil,
                  cancellation: RefreshCancellation? = nil, validateCommit: (() -> Bool)? = nil) throws -> LocalUsageSnapshot {
        try RefreshWork.$cancellation.withValue(cancellation) {
            while !lock.try() { try RefreshWork.check(); Thread.sleep(forTimeInterval: 0.02) }
            defer { lock.unlock(); copyLedger = nil; _ = malloc_zone_pressure_relief(nil, 0) }
            let previous = cache
            let previousStore = cacheStore
            do {
                return try autoreleasepool {
                    try PricingCatalog.$current.withValue(pricingProvider()) {
                        try scanLocked(weeklyWindow: weeklyWindow, accountContext: accountContext, invalidateWeeklyObservation: invalidateWeeklyObservation,
                                       rebuild: rebuild, quotaSampleAt: quotaSampleAt, validateCommit: validateCommit)
                    }
                }
            } catch {
                cache = previous
                cacheStore = previousStore
                throw error
            }
        }
    }

    private func scanLocked(weeklyWindow: RateLimitWindow?, accountContext: CodexAccountContext?,
                            invalidateWeeklyObservation: Bool, rebuild: Bool, quotaSampleAt: Date?, validateCommit: (() -> Bool)?) throws -> LocalUsageSnapshot {
        try RefreshWork.check()
        scanIssues = []
        rootStatuses = []
        let persistentLockFD = try cacheStore.acquireLock()
        defer { cacheStore.releaseLock(persistentLockFD) }

        let startedAt = Date()
        let now = nowProvider()
        let calendar = calendarProvider()
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now
        let historyStart = calendar.date(
            byAdding: .day,
            value: -Self.retainedHistoryDays,
            to: dayStart
        ) ?? dayStart.addingTimeInterval(-TimeInterval(Self.retainedHistoryDays * 24 * 60 * 60))
        let localDate = LocalUsageFormatting.localDateString(now, timeZone: calendar.timeZone)
        let timeZone = calendar.timeZone.identifier
        let rootURLs = rootURLsProvider().map(CodexPaths.canonical)
        let weeklyRoots = weeklyRootURLsProvider().map { CodexPaths.canonical($0).path }
        let source = LocalUsagePaths.localUsageSourceDescription(rootURLs: rootURLs)
        cacheStore.load(into: &cache)

        let previousRoots = cache.map { CodexPaths.canonicalPaths($0.rootPaths ?? $0.source.split(separator: ",").map(String.init)) } ?? []
        let currentRoots = Set(rootURLs.map(\.path))
        // Adding a Codex home must not erase an established observation.
        let canReuseBaseline = cache?.timeZone == timeZone
            && (cache?.source == source || (!previousRoots.isEmpty && previousRoots.isSubset(of: currentRoots)))
        let isColdScan: Bool
        var cacheChanged = false
        if !canReuseBaseline {
            cache = LocalUsageScanCache(
                source: source,
                localDate: localDate,
                timeZone: timeZone,
                dayStart: dayStart,
                dayEnd: dayEnd
            )
            isColdScan = true
            cacheChanged = true
        } else if cache?.localDate != localDate, let previous = cache {
            cache = LocalUsageScanCache(
                source: source,
                localDate: localDate,
                timeZone: timeZone,
                dayStart: dayStart,
                dayEnd: dayEnd,
                files: previous.files.mapValues { $0.resetForNewDay() },
                weeklyCostObservation: previous.weeklyCostObservation,
                pricing: previous.pricing
            )
            isColdScan = false
            cacheChanged = true
        } else {
            cache?.dayStart = dayStart
            cache?.dayEnd = dayEnd
            isColdScan = false
        }

        guard var cache else {
            throw RuntimeError("local usage cache unavailable")
        }
        var pricing = PricingCatalog.current.metadata
        if let previous = cache.pricing {
            pricing.previousFingerprint = previous.previousFingerprint
            pricing.previousAPIVersion = previous.previousAPIVersion
            pricing.previousCreditsVersion = previous.previousCreditsVersion
            pricing.changedAtIso = previous.changedAtIso
            if previous.fingerprint != pricing.fingerprint {
                pricing.previousFingerprint = previous.fingerprint
                pricing.previousAPIVersion = previous.api.version
                pricing.previousCreditsVersion = previous.credits.version
                pricing.changedAtIso = ISO8601DateFormatter().string(from: now)
            }
        }
        if cache.pricing != pricing { cache.pricing = pricing; cacheChanged = true }
        if cache.source != source {
            cache.source = source
            cacheChanged = true
        }

        if cache.rootPaths != rootURLs.map(\.path) {
            cache.rootPaths = rootURLs.map(\.path)
            cacheChanged = true
        }
        let discoveryStart = max(historyStart, min(dayStart, cache.weeklyCostObservation?.startedAt ?? dayStart))
        var byPath: [String: JsonlFileInfo] = [:]
        for root in rootURLs {
            try RefreshWork.check()
            let discovery = try LocalUsageLog.walkJsonlFileInfos(root: root, dayStart: historyStart, allowMissing: allowMissingRoots)
            scanIssues.append(contentsOf: discovery.issues)
            rootStatuses.append(discovery.root)
            for var file in discovery.files {
                guard rebuild || file.modifiedAt >= discoveryStart || cache.files[file.url.path] != nil else { continue }
                let state = cache.files[file.url.path]
                file.sessionID = state?.fileStamp == file.stamp ? state?.primarySessionId : try autoreleasepool {
                    try UsageFileIdentity.sessionID(at: file.url)
                }
                // An unreadable replacement must remain in its old copy
                // transaction until its new session identity is available.
                if file.sessionID == nil {
                    file.sessionID = state?.primarySessionId
                }
                byPath[file.url.path] = file
            }
        }
        let files = byPath.values.sorted { $0.url.path < $1.url.path }
        var stats = LocalUsageScanStats()
        stats.filesScanned = files.count

        if invalidateWeeklyObservation, cache.weeklyCostObservation != nil {
            cache.weeklyCostObservation = nil
            for path in Array(cache.files.keys) {
                cache.files[path]?.weeklyCost = nil
                cache.files[path]?.weeklyTimeline = nil
                cache.files[path]?.weeklyCopyHistoryConflict = nil
            }
            cacheChanged = true
        }
        let canUpdateObservation = quotaSampleAt.map {
            $0 <= now.addingTimeInterval(5) && now.timeIntervalSince($0) <= WeeklyQuotaEstimator.freshness
                && $0 >= (cache.weeklyCostObservation?.history?.samples.last?.timestamp ?? .distantPast)
        } ?? true
        if canUpdateObservation {
            cacheChanged = updateWeeklyCostObservation(
                cache: &cache, window: weeklyWindow, now: now, rootPaths: weeklyRoots, accountContext: accountContext
            ) || cacheChanged
        }
        if cache.weeklyCostObservation != nil, cache.weeklyCostObservation?.timelineStartedAt == nil {
            // Keep the original observation. Fine-grained evidence begins
            // now; old aggregate totals cannot reconstruct timed samples.
            cache.weeklyCostObservation?.timelineStartedAt = now
            cacheChanged = true
        }
        timelineStartedAt = cache.weeklyCostObservation?.timelineStartedAt.map {
            max($0, now.addingTimeInterval(-WeeklyQuotaEstimator.historyDuration
                - WeeklyQuotaEstimator.alignmentAllowance - WeeklyQuotaEstimator.bucketDuration))
        }
        cacheChanged = reconcileCachedFiles(files, cache: &cache, historyStart: historyStart) || cacheChanged

        let groups = Dictionary(grouping: files) { file in
            file.sessionID.map { "session:" + $0 } ?? "file:" + file.url.path
        }
        let missingSessions = Set(cache.files.compactMap { path, state in byPath[path] == nil ? state.primarySessionId : nil })
        for key in groups.keys.sorted() {
            try RefreshWork.check()
            let members = groups[key]!.sorted { $0.url.path < $1.url.path }
            let paths = members.map(\.url.path)
            let hasCopies = members.count > 1
            let replayCopies = hasCopies && (rebuild || members.contains { file in
                guard let state = cache.files[file.url.path] else { return true }
                return state.fileStamp != file.stamp || state.requiresCostRebuild || state.prefixDigest == nil || state.hasUsageBounds != true
                    || state.diagnostics?.version != UsageFileDiagnostics.currentVersion
                    || state.copyAlgorithmVersion != UsageCopyLedger.currentVersion || state.requiresBlankLineReplay
                    || state.copyMembers != paths || state.copyDay != localDate
            })
            let lostCopy = members.first?.sessionID.map { missingSessions.contains($0) } ?? false
            if lostCopy {
                for path in paths {
                    scanIssues.append(UsageScanIssue(kind: .copyReplayIncomplete, path: path, count: 1,
                                                    message: "A session copy is missing; retained the group's verified totals."))
                }
                continue
            }
            if hasCopies && !replayCopies { continue }
            // Unchanged copies entirely before the active day/observation
            // cannot overlap any newly counted event. Keep this common case
            // incremental even when their old histories diverge.
            let activityStart = min(dayStart, cache.weeklyCostObservation?.startedAt ?? dayStart)
            let changedMembers = members.filter { cache.files[$0.url.path]?.fileStamp != $0.stamp }
            if hasCopies, !rebuild, changedMembers.count == 1,
               members.allSatisfy({ file in
                   guard let state = cache.files[file.url.path] else { return false }
                   return state.copyMembers == paths && state.copyDay == localDate && state.hasUsageBounds == true
                       && state.prefixDigest != nil && !state.requiresCostRebuild
                       && state.diagnostics?.version == UsageFileDiagnostics.currentVersion
                       && state.copyAlgorithmVersion == UsageCopyLedger.currentVersion && !state.requiresBlankLineReplay
               }),
               members.filter({ $0.url.path != changedMembers[0].url.path }).allSatisfy({ file in
                   (cache.files[file.url.path]?.latestUsageAt ?? .distantPast) < activityStart
               }) {
                let file = changedMembers[0]
                let previousFailures = stats.readFailureCount
                cacheChanged = scan(file, cache: &cache, historyStart: historyStart, now: now, stats: &stats) || cacheChanged
                cache.files[file.url.path]?.copyMembers = paths
                cache.files[file.url.path]?.copyDay = localDate
                cache.files[file.url.path]?.copyAlgorithmVersion = UsageCopyLedger.currentVersion
                if stats.readFailureCount > previousFailures {
                    scanIssues.append(UsageScanIssue(kind: .copyReplayIncomplete, path: file.url.path, count: 1,
                                                    message: "Could not refresh session copies; retained their previous totals."))
                }
                continue
            }
            let previousStates = Dictionary(uniqueKeysWithValues: paths.compactMap { path in cache.files[path].map { (path, $0) } })
            let previousFailures = stats.readFailureCount
            if replayCopies { copyLedger = UsageCopyLedger(trackWeekly: cache.weeklyCostObservation != nil) }
            for file in members {
                copyLedger?.path = file.url.path
                copyLedger?.isWeeklySource = weeklyRoots.contains { file.url.path.hasPrefix($0 + "/") }
                let wasCopy = (cache.files[file.url.path]?.copyMembers?.count ?? 0) > 1
                cacheChanged = scan(file, cache: &cache, historyStart: historyStart, now: now, stats: &stats,
                                    force: rebuild || replayCopies || (wasCopy && !hasCopies)) || cacheChanged
                if hasCopies {
                    cache.files[file.url.path]?.copyMembers = paths
                    cache.files[file.url.path]?.copyDay = localDate
                    cache.files[file.url.path]?.copyAlgorithmVersion = UsageCopyLedger.currentVersion
                }
            }
            let completedLedger = copyLedger
            copyLedger = nil
            if replayCopies && stats.readFailureCount > previousFailures {
                for path in paths { cache.files[path] = previousStates[path] }
                for path in paths {
                    scanIssues.append(UsageScanIssue(kind: .copyReplayIncomplete, path: path, count: 1,
                                                    message: "Could not rebuild session copies; retained their previous totals."))
                }
            } else if let completedLedger {
                try applyCopyContributions(completedLedger, cache: &cache)
                for path in paths {
                    cache.files[path]?.copyHistoryConflict = completedLedger.hasDailyConflict
                    cache.files[path]?.weeklyCopyHistoryConflict = completedLedger.hasWeeklyConflict
                }
            }
        }

        for path in cache.files.keys where byPath[path] == nil {
            scanIssues.append(UsageScanIssue(kind: .fileMissing, path: path, count: 1,
                                            message: "A previously scanned file is missing or inaccessible; cached totals are retained."))
        }

        let cutoffMinute = WeeklyQuotaEstimator.minute(now.addingTimeInterval(-WeeklyQuotaEstimator.historyDuration
            - WeeklyQuotaEstimator.alignmentAllowance - WeeklyQuotaEstimator.bucketDuration))
        for path in cache.files.keys {
            if cache.files[path]?.weeklyTimeline?.keys.contains(where: { $0 < cutoffMinute }) == true {
                let retained = cache.files[path]?.weeklyTimeline?.filter { $0.key >= cutoffMinute }
                cache.files[path]?.weeklyTimeline = retained
                cacheChanged = true
            }
        }
        if let window = weeklyWindow, let sampledAt = quotaSampleAt,
           let observation = cache.weeklyCostObservation, observation.windowID == QuotaWindowID(window: window),
           sampledAt >= observation.startedAt.addingTimeInterval(-WeeklyQuotaEstimator.freshness) {
            var history = observation.history ?? WeeklyQuotaHistory()
            let previous = history.samples
            history.observe(usedPercent: window.usedPercent, at: sampledAt, now: now)
            if previous != history.samples {
                cache.weeklyCostObservation?.history = history
                cacheChanged = true
            }
        }
        let snapshot = makeSnapshot(
            cache: cache,
            filesScanned: files.count,
            now: now,
            weeklyWindow: weeklyWindow,
            accountContext: accountContext,
            quotaSampleAt: quotaSampleAt
        )
        try RefreshWork.check()
        guard validateCommit?() ?? true else { throw RuntimeError("Codex account changed while scanning; discarded the result.") }
        self.cache = cache
        if cacheChanged { cacheStore.persist(cache) }
        stats.durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        log(stats: stats, coldScan: isColdScan)
        return snapshot
    }

    private func applyCopyContributions(_ ledger: UsageCopyLedger, cache: inout LocalUsageScanCache) throws {
        var latestDates: [String: Date] = [:]
        for event in try ledger.resolvedContributions() {
            try RefreshWork.check()
            if let path = event.dailyOwner, var state = cache.files[path] {
                state.totals.add(event.usage)
                var cost = state.dailyCost ?? TokenCostAccumulator()
                cost.add(usage: event.usage, model: event.model, requestInputTokens: event.requestInput, serviceTier: event.tier)
                state.dailyCost = cost
                state.eventCount += 1
                let latest = latestDates[path] ?? timestampParser.parse(state.lastEventAtIso) ?? .distantPast
                if latest < event.sampledAt {
                    state.lastEventAtIso = event.timestamp
                }
                latestDates[path] = max(latest, event.sampledAt)
                cache.files[path] = state
            }
            if let path = event.weeklyOwner {
                var cost = cache.files[path]?.weeklyCost ?? TokenCostAccumulator()
                cost.add(usage: event.usage, model: event.model, requestInputTokens: event.requestInput, serviceTier: event.tier)
                cache.files[path]?.weeklyCost = cost
                addTimeline(usage: event.usage, model: event.model, requestInput: event.requestInput, tier: event.tier,
                            at: event.sampledAt, state: &cache.files[path]!)
            }
        }
    }

    private func addTimeline(usage: TokenUsage, model: String?, requestInput: Int64?, tier: String?,
                             at timestamp: Date, state: inout LocalUsageFileState) {
        guard let timelineStartedAt, timestamp >= timelineStartedAt else { return }
        let minute = WeeklyQuotaEstimator.minute(timestamp)
        if state.weeklyTimeline == nil { state.weeklyTimeline = [:] }
        state.weeklyTimeline?[minute, default: WeeklyCostBucket()].add(usage: usage, model: model, requestInput: requestInput, tier: tier)
    }

    private func reconcileCachedFiles(
        _ files: [JsonlFileInfo],
        cache: inout LocalUsageScanCache,
        historyStart: Date
    ) -> Bool {
        var changed = false
        let currentPaths = Set(files.map(\.url.path))
        let filesBySession = Dictionary(grouping: files.filter { $0.sessionID != nil }) { $0.sessionID! }
        for path in Array(cache.files.keys).sorted() where !currentPaths.contains(path) {
            guard let old = cache.files[path] else { continue }
            // Legacy caches may retain a moved path without a fingerprint.
            // An entry with no current contribution cannot cause overlap;
            // retire it so it cannot block replay of the archived history.
            if old.totals.totalTokens == 0, old.eventCount == 0, old.importedEventCount == 0,
               old.parseErrorCount == 0, old.weeklyCost == nil,
               (old.diagnostics?.invalidUsageRecords ?? 0) == 0, (old.diagnostics?.oversizedRecords ?? 0) == 0 {
                cache.files.removeValue(forKey: path)
                changed = true
                continue
            }
            for file in old.primarySessionId.flatMap({ filesBySession[$0] }) ?? [] {
                var sameContent = old.fileStamp?.identity == file.stamp.identity
                if !sameContent, file.size >= old.offset, let expected = old.prefixDigest,
                   let handle = try? FileHandle(forReadingFrom: file.url) {
                    defer { try? handle.close() }
                    sameContent = (try? UsageFileIdentity.digest(UsageFileIdentity.prefixHasher(handle, count: old.offset))) == expected
                }
                guard sameContent else { continue }
                if cache.files[file.url.path] == nil {
                    cache.files[file.url.path] = old
                } else {
                    // A copy can own zero daily contributions while another
                    // copy owns the shared prefix. Replay before retiring it.
                    cache.files[file.url.path]?.prefixDigest = nil
                }
                cache.files.removeValue(forKey: path)
                changed = true
                break
            }
        }

        let livePaths = Set(files.map(\.url.path))
        for path in Array(cache.files.keys) {
            guard let state = cache.files[path] else { continue }
            let shouldKeep = livePaths.contains(path)
                || state.modifiedAt.map { $0 >= historyStart } == true
            if shouldKeep {
                continue
            } else {
                cache.files.removeValue(forKey: path)
                changed = true
            }
        }
        return changed
    }

    private func updateWeeklyCostObservation(
        cache: inout LocalUsageScanCache,
        window: RateLimitWindow?,
        now: Date,
        rootPaths: [String],
        accountContext: CodexAccountContext?
    ) -> Bool {
        guard accountContext == nil || accountContext?.scopeKey != nil else { return false }
        guard let window,
              let windowID = QuotaWindowID(window: window),
              let durationMinutes = window.windowDurationMins,
              let windowEnd = window.resetDate
        else {
            return false
        }
        let windowStart = windowEnd.addingTimeInterval(-TimeInterval(durationMinutes * 60))
        guard windowStart <= now, now <= windowEnd else { return false }

        let usedPercent = max(0, min(100, max(window.usedPercent, 100 - window.remainingPercent)))
        if let observation = cache.weeklyCostObservation,
           observation.accountScopeKey == accountContext?.scopeKey,
           observation.windowID == windowID,
           observation.startedAt >= windowStart,
           observation.startedAt <= now,
           observation.baselineUsedPercent <= usedPercent,
           observation.rootPaths.map({ CodexPaths.canonicalPaths($0).isSubset(of: Set(rootPaths)) }) ?? true {
            if observation.rootPaths != rootPaths {
                cache.weeklyCostObservation?.rootPaths = rootPaths
                return true
            }
            return false
        }

        cache.weeklyCostObservation = LocalUsageWeeklyCostObservation(
            windowID: windowID,
            startedAt: now,
            baselineUsedPercent: usedPercent,
            rootPaths: rootPaths,
            accountScopeKey: accountContext?.scopeKey,
            timelineStartedAt: now
        )
        for path in Array(cache.files.keys) {
            cache.files[path]?.weeklyCost = nil
            cache.files[path]?.weeklyTimeline = nil
            cache.files[path]?.weeklyCopyHistoryConflict = nil
        }
        return true
    }

    private func scan(
        _ file: JsonlFileInfo, cache: inout LocalUsageScanCache, historyStart: Date,
        now: Date, stats: inout LocalUsageScanStats, force: Bool = false
    ) -> Bool {
        let path = file.url.path
        let previousState = cache.files[path]
        var state = previousState ?? LocalUsageFileState()
        var replay = force || state.requiresCostRebuild || state.prefixDigest == nil || state.hasUsageBounds != true
            || state.diagnostics?.version != UsageFileDiagnostics.currentVersion
            || state.requiresBlankLineReplay
            || file.size < state.offset || state.fileStamp?.identity != file.stamp.identity
        if !replay, state.fileStamp == file.stamp, file.size == state.offset { return false }
        do {
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            var hasher = SHA256()
            if !replay {
                hasher = try UsageFileIdentity.prefixHasher(handle, count: state.offset)
                stats.verificationBytes += state.offset
                if UsageFileIdentity.digest(hasher) != state.prefixDigest { replay = true }
            }
            if replay {
                state = LocalUsageFileState()
                state.diagnostics = UsageFileDiagnostics()
                hasher = SHA256()
                stats.fullRescanFiles += 1
            }
            try handle.seek(toOffset: state.offset)
            var remaining = file.size - state.offset
            while remaining > 0 {
                try RefreshWork.check()
                let count = min(Self.readChunkSize, Int(remaining))
                if readBuffer.count != Self.readChunkSize { readBuffer = Data(count: Self.readChunkSize) }
                let bytesRead = readBuffer.withUnsafeMutableBytes { buffer -> Int in
                    guard let baseAddress = buffer.baseAddress else { return 0 }
                    var result: Int
                    repeat { result = Darwin.read(handle.fileDescriptor, baseAddress, count) } while result < 0 && errno == EINTR
                    return result
                }
                guard bytesRead > 0 else { throw RuntimeError("Session file changed or could not be read") }
                let chunk = readBuffer.prefix(bytesRead)
                hasher.update(data: chunk)
                state.offset += UInt64(bytesRead)
                remaining -= UInt64(bytesRead)
                stats.bytesRead += UInt64(bytesRead)
                process(data: chunk, state: &state, dayStart: cache.dayStart, dayEnd: cache.dayEnd,
                        historyStart: historyStart, weeklyObservationStart: cache.weeklyCostObservation?.startedAt, now: now)
            }
            if UsageFileStamp.read(file.url) != file.stamp {
                guard let current = UsageFileStamp.read(file.url), current.identity == file.stamp.identity,
                      current.size >= file.size,
                      UsageFileIdentity.digest(try UsageFileIdentity.prefixHasher(handle, count: file.size)) == UsageFileIdentity.digest(hasher)
                else { throw RuntimeError("Session file changed during scanning; retrying on the next refresh") }
                stats.verificationBytes += file.size
            }
            state.size = file.size
            state.modifiedAt = file.modifiedAt
            state.fileStamp = file.stamp
            state.hasUsageBounds = true
            state.diagnostics?.blankLinesChecked = true
            state.prefixDigest = UsageFileIdentity.digest(hasher)
            cache.files[path] = state
            stats.filesRead += 1
            return true
        } catch {
            stats.readFailureCount += 1
            scanIssues.append(UsageScanIssue(kind: .fileReadFailed, path: path, count: 1, message: errorMessage(error)))
            appendSharedLog("local usage scan read failure: \(path): \(errorMessage(error))")
            // Commit the cursor and totals together only after a verified read.
            return false
        }
    }

    private func process(
        data: Data,
        state: inout LocalUsageFileState,
        dayStart: Date,
        dayEnd: Date,
        historyStart: Date,
        weeklyObservationStart: Date?,
        now: Date
    ) {
        guard !data.isEmpty else { return }
        if state.pendingData.count > Self.maxBufferedLineSize {
            state.diagnostics?.oversizedRecords += 1
            state.pendingData.removeAll(keepingCapacity: false)
            state.isSkippingOversizedLine = true
        }

        var cursor = data.startIndex
        while cursor < data.endIndex {
            if state.isSkippingOversizedLine == true {
                guard let newlineIndex = data[cursor...].firstIndex(of: 0x0A) else { return }
                state.isSkippingOversizedLine = false
                cursor = data.index(after: newlineIndex)
                continue
            }

            guard let newlineIndex = data[cursor...].firstIndex(of: 0x0A) else {
                let fragment = data[cursor...]
                if state.pendingData.count + fragment.count > Self.maxBufferedLineSize {
                    state.diagnostics?.oversizedRecords += 1
                    state.pendingData.removeAll(keepingCapacity: false)
                    state.isSkippingOversizedLine = true
                } else {
                    state.pendingData.append(contentsOf: fragment)
                }
                return
            }

            let fragment = data[cursor..<newlineIndex]
            if state.pendingData.isEmpty {
                if fragment.count <= Self.maxBufferedLineSize {
                    processCompleteLine(
                        fragment,
                        state: &state,
                        dayStart: dayStart,
                        dayEnd: dayEnd,
                        historyStart: historyStart,
                        weeklyObservationStart: weeklyObservationStart,
                        now: now
                    )
                } else {
                    state.diagnostics?.oversizedRecords += 1
                }
            } else if state.pendingData.count + fragment.count <= Self.maxBufferedLineSize {
                state.pendingData.append(contentsOf: fragment)
                let completedLine = state.pendingData
                state.pendingData.removeAll(keepingCapacity: false)
                processCompleteLine(
                    completedLine,
                    state: &state,
                    dayStart: dayStart,
                    dayEnd: dayEnd,
                    historyStart: historyStart,
                    weeklyObservationStart: weeklyObservationStart,
                    now: now
                )
            } else {
                state.diagnostics?.oversizedRecords += 1
                state.pendingData.removeAll(keepingCapacity: false)
            }
            cursor = data.index(after: newlineIndex)
        }
    }

    private func processCompleteLine(
        _ data: Data,
        state: inout LocalUsageFileState,
        dayStart: Date,
        dayEnd: Date,
        historyStart: Date,
        weeklyObservationStart: Date?,
        now: Date
    ) {
        let lineData = trimmedLineData(data)
        guard lineData.contains(where: { ![0x20, 0x09, 0x0D].contains($0) }) else { return }
        autoreleasepool {
            processLine(
                lineData,
                state: &state,
                dayStart: dayStart,
                dayEnd: dayEnd,
                historyStart: historyStart,
                weeklyObservationStart: weeklyObservationStart,
                now: now
            )
        }
    }

    private func trimmedLineData(_ data: Data) -> Data {
        guard data.last == 0x0D else { return data }
        return data.dropLast()
    }

    private func processLine(
        _ lineData: Data,
        state: inout LocalUsageFileState,
        dayStart: Date,
        dayEnd: Date,
        historyStart: Date,
        weeklyObservationStart: Date?,
        now: Date
    ) {
        guard !LocalUsageLog.isBlankLine(lineData) else { return }
        let object: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  stringValue(value["type"]) != nil else {
                state.diagnostics?.invalidUsageRecords += 1
                return
            }
            object = value
        } catch {
            state.parseErrorCount += 1
            return
        }
        state.diagnostics?.validRecords += 1

        if let sessionId = LocalUsageLog.sessionIdFromMeta(object) {
            if state.primarySessionId == nil {
                state.primarySessionId = sessionId
            }
            state.activeSessionId = sessionId
            state.currentServiceTier = dictionaryValue(object["payload"]).flatMap(LocalUsageLog.serviceTierFromPayload)
            if let payload = dictionaryValue(object["payload"]),
               let model = LocalUsageLog.modelFromPayload(payload) {
                state.currentModel = model
            }
            return
        }

        if stringValue(object["type"]) == "session_meta" {
            state.diagnostics?.invalidUsageRecords += 1
            return
        }
        if stringValue(object["type"]) == "turn_context" {
            guard let payload = dictionaryValue(object["payload"]) else {
                state.diagnostics?.invalidUsageRecords += 1
                return
            }
            // A full turn context replaces the tier, including an absent tier.
            state.currentServiceTier = LocalUsageLog.serviceTierFromPayload(payload)
            state.currentModel = LocalUsageLog.modelFromPayload(payload)
            return
        }

        guard stringValue(object["type"]) == "event_msg" else { return }
        guard let payload = dictionaryValue(object["payload"]),
              let eventType = stringValue(payload["type"])
        else {
            state.diagnostics?.invalidUsageRecords += 1
            return
        }
        if eventType == "thread_settings_applied" {
            if LocalUsageLog.hasServiceTierSetting(payload) {
                state.currentServiceTier = LocalUsageLog.serviceTierFromPayload(payload)
            }
            if let model = LocalUsageLog.modelFromPayload(payload) {
                state.currentModel = model
            }
            return
        }

        guard eventType == "token_count" else { return }
        // Rate-limit-only updates have no token sample to account for.
        if (payload["info"] == nil || payload["info"] is NSNull), payload["rate_limits"] != nil { return }
        guard let info = dictionaryValue(payload["info"]),
              let currentTotalUsage = TokenUsage.from(info["total_token_usage"])
        else {
            state.diagnostics?.invalidUsageRecords += 1
            return
        }

        let timestamp = timestampParser.parse(stringValue(object["timestamp"]))
        guard timestamp != nil else {
            state.diagnostics?.invalidUsageRecords += 1
            return
        }
        if let timestamp, timestamp > (state.latestUsageAt ?? .distantPast) { state.latestUsageAt = timestamp }
        let isToday = timestamp.map { $0 >= dayStart && $0 < dayEnd } ?? false
        if isToday { state.diagnostics?.todayUsageEvents += 1 }
        let isInHistory = timestamp.map { $0 >= historyStart && $0 < dayEnd } ?? false
        let isImportedForkEvent = state.primarySessionId != nil
            && state.activeSessionId != nil
            && state.activeSessionId != state.primarySessionId
        let sameSession = state.previousUsageSessionId == state.activeSessionId
        let baseline = sameSession ? state.previousTotalUsage : state.previousObservedTotalUsage
        let regressed = sameSession && LocalUsageLog.usageRegressed(baseline, currentTotalUsage)
        let delta = LocalUsageLog.positiveDelta(baseline, currentTotalUsage, sameSession: sameSession)

        let model = LocalUsageLog.modelFromPayload(info) ?? LocalUsageLog.modelFromPayload(payload) ?? state.currentModel
        let requestInputTokens = TokenUsage.nonnegativeInteger(dictionaryValue(info["last_token_usage"])?["input_tokens"])
        let serviceTier = LocalUsageLog.serviceTierFromPayload(info)
            ?? LocalUsageLog.serviceTierFromPayload(payload) ?? state.currentServiceTier
        let eventKey = copyLedger.map { _ in
            UsageCopyLedger.eventKey(session: state.primarySessionId, activeSession: state.activeSessionId,
                                     timestamp: timestamp, usage: currentTotalUsage, model: model, tier: serviceTier,
                                     requestInput: requestInputTokens, imported: isImportedForkEvent)
        }
        let countToday = isToday && (eventKey.map { copyLedger!.claimDaily($0) } ?? true)
        let countWeekly = timestamp.map { time in
            weeklyObservationStart.map { time > $0 && time <= now } ?? false
        } ?? false
        if let copyLedger, let eventKey, !isImportedForkEvent, !regressed {
            copyLedger.observe(key: eventKey, current: currentTotalUsage, delta: delta, continuing: sameSession,
                model: model, tier: serviceTier, requestInput: requestInputTokens, timestamp: timestamp!,
                timestampText: stringValue(object["timestamp"]), today: isToday && isInHistory,
                inWeeklyWindow: countWeekly && isInHistory)
        }
        if isInHistory {
            if isImportedForkEvent {
                if countToday {
                    state.importedEventCount += 1
                }
            } else if let delta {
                if copyLedger == nil {
                    if countToday {
                        state.totals.add(delta)
                        var dailyCost = state.dailyCost ?? TokenCostAccumulator()
                        dailyCost.add(
                            usage: delta,
                            model: model,
                            requestInputTokens: requestInputTokens,
                            serviceTier: serviceTier
                        )
                        state.dailyCost = dailyCost
                        state.eventCount += 1
                        state.lastEventAtIso = stringValue(object["timestamp"])
                    }
                    if countWeekly {
                        var weeklyCost = state.weeklyCost ?? TokenCostAccumulator()
                        weeklyCost.add(
                            usage: delta,
                            model: model,
                            requestInputTokens: requestInputTokens,
                            serviceTier: serviceTier
                        )
                        state.weeklyCost = weeklyCost
                        if let timestamp {
                            addTimeline(usage: delta, model: model, requestInput: requestInputTokens, tier: serviceTier,
                                        at: timestamp, state: &state)
                        }
                    }
                }
            } else if countToday {
                state.duplicateEventCount += 1
                if regressed {
                    state.regressionEventCount += 1
                }
                state.eventCount += 1
                state.lastEventAtIso = stringValue(object["timestamp"])
            }
        }

        if sameSession || !LocalUsageLog.usageRegressed(state.previousTotalUsage, currentTotalUsage) {
            state.previousTotalUsage = LocalUsageLog.maxTokenUsage(state.previousTotalUsage, currentTotalUsage)
        } else {
            state.previousTotalUsage = currentTotalUsage
        }
        state.previousUsageSessionId = state.activeSessionId
        state.previousObservedTotalUsage = currentTotalUsage
    }

    private func makeSnapshot(
        cache: LocalUsageScanCache,
        filesScanned: Int,
        now: Date,
        weeklyWindow: RateLimitWindow?,
        accountContext: CodexAccountContext?, quotaSampleAt: Date?
    ) -> LocalUsageSnapshot {
        var totals = TokenUsage()
        var topFiles: [LocalUsageTopFile] = []
        var eventCount = 0
        var duplicateEventCount = 0
        var importedEventCount = 0
        var regressionEventCount = 0
        var filesWithEvents = 0
        var parseErrorCount = 0
        var todayCostAccumulator = TokenCostAccumulator()
        var weeklyCostAccumulator = TokenCostAccumulator()
        var weeklyTimeline: [Int: WeeklyCostBucket] = [:]
        let weeklyRoots = cache.weeklyCostObservation?.rootPaths ?? weeklyRootURLsProvider().map(\.path)

        for (path, state) in cache.files {
            totals.add(state.totals)
            eventCount += state.eventCount
            duplicateEventCount += state.duplicateEventCount
            importedEventCount += state.importedEventCount
            regressionEventCount += state.regressionEventCount
            parseErrorCount += state.parseErrorCount
            if let dailyCost = state.dailyCost {
                todayCostAccumulator.merge(dailyCost)
            }
            // Daily usage spans local homes, while quota observations must
            // match the home used by the official rate-limit request.
            if let weeklyCost = state.weeklyCost {
                let canonicalPath = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
                if weeklyRoots.contains(where: { canonicalPath.hasPrefix($0 + "/") }) {
                    weeklyCostAccumulator.merge(weeklyCost)
                    for (minute, bucket) in state.weeklyTimeline ?? [:] {
                        weeklyTimeline[minute, default: WeeklyCostBucket()].merge(bucket)
                    }
                }
            }

            guard state.eventCount > 0 else { continue }
            filesWithEvents += 1
            topFiles.append(LocalUsageTopFile(
                file: path,
                eventCount: state.eventCount,
                duplicateEventCount: state.duplicateEventCount,
                importedEventCount: state.importedEventCount,
                regressionEventCount: state.regressionEventCount,
                primarySessionId: state.primarySessionId,
                totalTokens: state.totals.totalTokens,
                lastEventAtIso: state.lastEventAtIso,
                sourceFiles: state.copyMembers ?? [path]
            ))
        }

        let cacheHitPercent = totals.hasCompleteBreakdown && totals.inputTokens > 0
            ? max(0, min(100, (Double(totals.cachedInputTokens) / Double(totals.inputTokens)) * 100))
            : nil
        topFiles.sort { $0.totalTokens > $1.totalTokens }
        let todayCost = todayCostAccumulator.estimate()
        let todayCredits = todayCostAccumulator.creditEstimate()
        let diagnostics = makeDiagnostics(cache: cache, filesDiscovered: filesScanned)
        let assumptions = todayCostAccumulator.billingAssumptions()
        let weeklyDiagnostics = makeDiagnostics(cache: cache, filesDiscovered: filesScanned, roots: weeklyRoots)
        var weeklyQuotaCost = makeWeeklyQuotaCost(
            observed: weeklyCostAccumulator.estimate(),
            window: weeklyWindow,
            observation: cache.weeklyCostObservation,
            now: now,
            diagnostics: weeklyDiagnostics,
            assumptions: weeklyCostAccumulator.billingAssumptions(),
            timeline: weeklyTimeline, quotaSampleAt: quotaSampleAt
        )
        weeklyQuotaCost?.unpricedUsage = weeklyCostAccumulator.unpricedUsage()
        let unpricedUsage = todayCostAccumulator.unpricedUsage()

        var snapshot = LocalUsageSnapshot(
            fetchedAtIso: ISO8601DateFormatter().string(from: now),
            source: cache.source,
            timezone: cache.timeZone,
            localDate: cache.localDate,
            inputTokens: totals.inputTokens,
            cachedInputTokens: totals.cachedInputTokens,
            cacheWriteInputTokens: totals.cacheWriteInputTokens,
            outputTokens: totals.outputTokens,
            reasoningOutputTokens: totals.reasoningOutputTokens,
            totalTokens: totals.totalTokens,
            cacheHitPercent: cacheHitPercent,
            eventCount: eventCount,
            duplicateEventCount: duplicateEventCount,
            importedEventCount: importedEventCount,
            regressionEventCount: regressionEventCount,
            filesScanned: filesScanned,
            filesWithEvents: filesWithEvents,
            parseErrorCount: parseErrorCount,
            error: diagnostics.status.isIncomplete ? AppText.scanStatus(diagnostics) : nil,
            topFiles: Array(topFiles.prefix(8)),
            todayCost: todayCost,
            weeklyQuotaCost: weeklyQuotaCost,
            display: LocalUsageDisplay(
                consumptionLabel: AppText.consumption(diagnostics.status == .unavailable ? nil : TokenAmountFormatter.compact(totals.totalTokens))
                    + (diagnostics.status == .partial ? "*" : ""),
                cacheHitLabel: AppText.cacheHit(diagnostics.status == .unavailable ? nil : LocalUsageFormatting.formatCacheHitPercent(cacheHitPercent)),
                estimatedCostLabel: AppText.todayEstimatedCost(diagnostics.status == .unavailable ? nil : todayCost),
                weeklyQuotaCostLabel: weeklyWindow == nil
                    ? nil
                    : AppText.weeklyQuotaEstimatedCost(weeklyQuotaCost),
                estimatedCreditsLabel: AppText.todayEstimatedCredits(diagnostics.status == .unavailable ? nil : todayCredits),
                pricingCoverageLabel: AppText.pricingCoverage(cost: todayCost, credits: todayCredits),
                scanStatusLabel: AppText.scanStatus(diagnostics),
                billingAssumptionsLabel: AppText.billingAssumptions(assumptions),
                pricingVersionLabel: AppText.pricingVersion(cache.pricing),
                unpricedUsageDetails: AppText.unpricedUsageDetails(unpricedUsage)
            ),
            todayCredits: todayCredits,
            accountContext: accountContext,
            diagnostics: diagnostics,
            billingAssumptions: assumptions,
            pricing: cache.pricing,
            unpricedUsage: unpricedUsage
        )
        snapshot.freshness = RefreshCoordinator.oneShot([.localUsage: RefreshOutcome.local(snapshot)], attemptedAt: now, now: Date()).localUsage
        return snapshot
    }

    private func makeDiagnostics(cache: LocalUsageScanCache, filesDiscovered: Int, roots: [String]? = nil) -> UsageScanDiagnostics {
        func includes(_ path: String?) -> Bool {
            guard let roots, let path else { return true }
            return roots.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
        }
        var issues = scanIssues.filter { includes($0.path) }
        var validRecords = 0, usageEvents = 0, filesVerified = 0
        let failedPaths = Set(scanIssues.filter { $0.kind == .fileReadFailed || $0.kind == .fileMissing }.compactMap(\.path))
        for (path, state) in cache.files.sorted(by: { $0.key < $1.key }) where includes(path) {
            let file = state.diagnostics
            validRecords += file?.validRecords ?? (state.totals.totalTokens > 0 ? 1 : 0)
            usageEvents += file?.todayUsageEvents ?? 0
            if file?.version == UsageFileDiagnostics.currentVersion, !failedPaths.contains(path) { filesVerified += 1 }
            func append(_ kind: UsageScanIssue.Kind, _ count: Int, _ message: String) {
                if count > 0 { issues.append(UsageScanIssue(kind: kind, path: path, count: count, message: message)) }
            }
            append(.invalidJSON, state.parseErrorCount, "Malformed JSON records could not be read.")
            let copyConflict = roots == nil ? state.copyHistoryConflict : state.weeklyCopyHistoryConflict
            append(.copyReplayIncomplete, copyConflict == true ? 1 : 0,
                   "Session copies contain incompatible cumulative histories; some overlaps could not be resolved.")
            append(.invalidUsage, file?.invalidUsageRecords ?? 0, "Records lack valid usage totals, timestamps or required event fields.")
            append(.oversizedRecord, file?.oversizedRecords ?? 0, "Records exceed the 8 MB parsing limit; their effect on usage could not be verified.")
            append(.pendingRecord, !state.pendingData.isEmpty || state.isSkippingOversizedLine == true ? 1 : 0,
                   "The last record is not complete; it will be retried after the next append.")
            if file?.version != UsageFileDiagnostics.currentVersion {
                append(.cacheUnavailable, 1, "Cached statistics have not yet been verified with the current parser.")
            }
        }
        issues.sort { ($0.path ?? "", $0.kind.rawValue) < ($1.path ?? "", $1.kind.rawValue) }
        return .make(roots: rootStatuses.filter { includes($0.path) }, filesDiscovered: filesDiscovered,
                     filesVerified: filesVerified, validRecords: validRecords, usageEvents: usageEvents, issues: issues)
    }

    private func makeWeeklyQuotaCost(
        observed: UsageCostEstimate,
        window: RateLimitWindow?,
        observation: LocalUsageWeeklyCostObservation?,
        now: Date,
        diagnostics: UsageScanDiagnostics,
        assumptions: UsageBillingAssumptions,
        timeline: [Int: WeeklyCostBucket], quotaSampleAt: Date?
    ) -> WeeklyQuotaCostEstimate? {
        guard let window,
              let windowID = QuotaWindowID(window: window),
              let observation,
              observation.windowID == windowID,
              let durationMinutes = window.windowDurationMins,
              durationMinutes > 0,
              let windowEnd = window.resetDate
        else {
            return nil
        }
        let windowStart = windowEnd.addingTimeInterval(-TimeInterval(durationMinutes * 60))
        guard windowStart <= now, now <= windowEnd else { return nil }

        let usedPercent = max(0, min(100, max(window.usedPercent, 100 - window.remainingPercent)))
        let usedDeltaPercent = max(0, usedPercent - observation.baselineUsedPercent)
        let valuation = WeeklyQuotaEstimator.evaluate(history: observation.history ?? WeeklyQuotaHistory(), buckets: timeline,
            coverageStart: observation.timelineStartedAt ?? now, quotaSampleAt: quotaSampleAt,
            scanIncomplete: diagnostics.status.isIncomplete, now: now)
        let formatter = ISO8601DateFormatter()
        return WeeklyQuotaCostEstimate(
            windowStartIso: formatter.string(from: windowStart),
            windowEndIso: formatter.string(from: windowEnd),
            observationStartIso: formatter.string(from: observation.startedAt),
            baselineUsedPercent: observation.baselineUsedPercent,
            usedPercent: usedPercent,
            usedDeltaPercent: usedDeltaPercent,
            observedCostUSD: observed.estimatedCostUSD,
            estimatedQuotaUSD: valuation.estimatedUSD,
            coveragePercent: observed.coveragePercent,
            pricedTokens: observed.pricedTokens,
            unpricedTokens: observed.unpricedTokens,
            unpricedModels: observed.unpricedModels,
            source: observation.rootPaths?.joined(separator: ","),
            accountScopeKey: observation.accountScopeKey,
            scanStatus: diagnostics.status,
            billingAssumptions: assumptions,
            inferencePauseReason: valuation.reason,
            valuation: valuation
        )
    }

    private func log(stats: LocalUsageScanStats, coldScan: Bool) {
        guard stats.bytesRead > 0 || stats.fullRescanFiles > 0 || stats.readFailureCount > 0 || stats.durationMs > 1000 else {
            return
        }
        appendSharedLog("local usage scan files=\(stats.filesScanned) readFiles=\(stats.filesRead) bytes=\(stats.bytesRead) verificationBytes=\(stats.verificationBytes) durationMs=\(stats.durationMs) fullRescanFiles=\(stats.fullRescanFiles) cold=\(coldScan) readFailures=\(stats.readFailureCount)")
    }
}


private struct LocalUsageScanStats {
    var filesScanned = 0
    var filesRead = 0
    var bytesRead: UInt64 = 0
    var verificationBytes: UInt64 = 0
    var fullRescanFiles = 0
    var readFailureCount = 0
    var durationMs = 0
}
