import Foundation
import XCTest
@testable import CodexRateLimitsCore

final class LocalUsageScannerTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var calendar: Calendar!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRateLimitsCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testPreviousDayUsageOnlyProvidesTodaysBaseline() throws {
        let now = try date("2026-07-13T17:00:00Z")
        let file = temporaryDirectory.appendingPathComponent("rollout-cross-day.jsonl")
        try writeEvents([
            sessionMeta(id: "session-a", timestamp: "2026-07-13T15:58:00Z"),
            tokenCount(total: 100, timestamp: "2026-07-13T15:59:00Z"),
            tokenCount(total: 240, timestamp: "2026-07-13T16:01:00Z"),
        ], to: file, modifiedAt: now)

        let snapshot = try scanner(now: { now }).snapshot()

        XCTAssertEqual(snapshot.localDate, "2026-07-14")
        XCTAssertEqual(snapshot.timezone, "Asia/Shanghai")
        XCTAssertEqual(snapshot.totalTokens, 140)
        XCTAssertEqual(snapshot.eventCount, 1)
    }

    func testCacheResetsAtLocalMidnightWithoutLosingBaseline() throws {
        let clock = TestClock(try date("2026-07-13T14:30:00Z"))
        let file = temporaryDirectory.appendingPathComponent("rollout-midnight.jsonl")
        try writeEvents([
            sessionMeta(id: "session-a", timestamp: "2026-07-13T12:00:00Z"),
            tokenCount(total: 100, timestamp: "2026-07-13T13:00:00Z"),
            tokenCount(total: 150, timestamp: "2026-07-13T14:00:00Z"),
        ], to: file, modifiedAt: clock.now)
        let scanner = scanner(now: { clock.now })

        let firstDay = try scanner.snapshot()
        XCTAssertEqual(firstDay.localDate, "2026-07-13")
        XCTAssertEqual(firstDay.totalTokens, 150)

        clock.now = try date("2026-07-13T16:30:00Z")
        try appendEvent(tokenCount(total: 210, timestamp: "2026-07-13T16:10:00Z"), to: file, modifiedAt: clock.now)

        let secondDay = try scanner.snapshot()
        XCTAssertEqual(secondDay.localDate, "2026-07-14")
        XCTAssertEqual(secondDay.totalTokens, 60)
        XCTAssertEqual(secondDay.eventCount, 1)
    }

    func testTimeZoneChangeInvalidatesCachedDayBoundaries() throws {
        let now = try date("2026-07-13T16:30:00Z")
        let calendarClock = TestCalendar(calendar)
        let file = temporaryDirectory.appendingPathComponent("rollout-time-zone.jsonl")
        try writeEvents([
            sessionMeta(id: "session-a", timestamp: "2026-07-13T15:45:00Z"),
            tokenCount(total: 100, timestamp: "2026-07-13T15:50:00Z"),
            tokenCount(total: 150, timestamp: "2026-07-13T16:10:00Z"),
        ], to: file, modifiedAt: now)
        let scanner = CodexBackend.LocalUsageScanner(
            rootURLs: [temporaryDirectory],
            calendarProvider: { calendarClock.value },
            now: { now }
        )

        calendarClock.value.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let utcSnapshot = try scanner.snapshot()
        XCTAssertEqual(utcSnapshot.localDate, "2026-07-13")
        XCTAssertEqual(utcSnapshot.totalTokens, 150)

        calendarClock.value.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let shanghaiSnapshot = try scanner.snapshot()
        XCTAssertEqual(shanghaiSnapshot.localDate, "2026-07-14")
        XCTAssertEqual(shanghaiSnapshot.totalTokens, 50)
    }

    func testForkedHistoryIsBaselineButNotConsumption() throws {
        let now = try date("2026-07-14T04:00:00Z")
        let file = temporaryDirectory.appendingPathComponent("rollout-fork.jsonl")
        try writeEvents([
            sessionMeta(id: "fork-session", timestamp: "2026-07-14T00:00:00Z"),
            turnContext(model: "gpt-5.6-luna", timestamp: "2026-07-14T00:00:30Z"),
            sessionMeta(id: "parent-session", timestamp: "2026-07-14T00:01:00Z"),
            tokenCount(total: 1_000, timestamp: "2026-07-14T00:02:00Z"),
            tokenCount(total: 1_200, timestamp: "2026-07-14T00:03:00Z"),
            tokenCount(total: 900, timestamp: "2026-07-14T00:04:00Z"),
            sessionMeta(id: "fork-session", timestamp: "2026-07-14T00:05:00Z"),
            tokenCount(total: 910, timestamp: "2026-07-14T00:06:00Z"),
            tokenCount(total: 950, timestamp: "2026-07-14T00:07:00Z"),
        ], to: file, modifiedAt: now)

        let snapshot = try scanner(now: { now }).snapshot()

        XCTAssertEqual(snapshot.totalTokens, 50)
        XCTAssertEqual(snapshot.importedEventCount, 3)
        XCTAssertEqual(snapshot.eventCount, 2)
        XCTAssertEqual(snapshot.topFiles?.first?.primarySessionId, "fork-session")
        XCTAssertEqual(try XCTUnwrap(snapshot.todayCost?.estimatedCostUSD), 0.000_01, accuracy: 0.000_000_001)
        XCTAssertEqual(snapshot.todayCost?.models.first?.inputTokens, 50)
    }

    func testCostFollowsModelSwitches() throws {
        let now = try date("2026-07-14T04:00:00Z")
        let file = temporaryDirectory.appendingPathComponent("rollout-model-switch.jsonl")
        try writeEvents([
            sessionMeta(id: "session-a", timestamp: "2026-07-14T00:00:00Z"),
            turnContext(model: "gpt-5.6-luna", timestamp: "2026-07-14T00:00:30Z"),
            tokenCount(input: 1_000_000, total: 1_000_000, lastInput: 100_000, timestamp: "2026-07-14T00:01:00Z"),
            turnContext(model: "gpt-5.6-sol", timestamp: "2026-07-14T00:01:30Z"),
            tokenCount(input: 2_000_000, total: 2_000_000, lastInput: 100_000, timestamp: "2026-07-14T00:02:00Z"),
            turnContext(model: "gpt-6-astra", timestamp: "2026-07-14T00:02:30Z"),
            tokenCount(input: 3_000_000, total: 3_000_000, lastInput: 300_000, timestamp: "2026-07-14T00:03:00Z"),
        ], to: file, modifiedAt: now)

        let snapshot = try scanner(now: { now }).snapshot()

        XCTAssertEqual(snapshot.totalTokens, 3_000_000)
        XCTAssertEqual(try XCTUnwrap(snapshot.todayCost?.estimatedCostUSD), 24.20, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.todayCost?.coveragePercent, 100)
        XCTAssertEqual(snapshot.todayCost?.models.map(\.model), ["gpt-5.6-luna", "gpt-5.6-sol", "gpt-6-astra"])
    }

    func testCostSeparatesCacheWritesAndDoesNotDoubleCountReasoning() throws {
        let now = try date("2026-07-14T04:00:00Z")
        let file = temporaryDirectory.appendingPathComponent("rollout-token-types.jsonl")
        try writeEvents([
            sessionMeta(id: "session-a", timestamp: "2026-07-14T00:00:00Z"),
            turnContext(model: "gpt-5.6-luna", timestamp: "2026-07-14T00:00:30Z"),
            tokenCount(
                input: 1_000_000,
                cachedInput: 400_000,
                cacheWriteInput: 100_000,
                output: 100_000,
                reasoningOutput: 80_000,
                total: 1_100_000,
                lastInput: 200_000,
                timestamp: "2026-07-14T00:01:00Z"
            ),
        ], to: file, modifiedAt: now)

        let snapshot = try scanner(now: { now }).snapshot()

        XCTAssertEqual(snapshot.cacheWriteInputTokens, 100_000)
        XCTAssertEqual(snapshot.reasoningOutputTokens, 80_000)
        XCTAssertEqual(try XCTUnwrap(snapshot.todayCost?.estimatedCostUSD), 0.253, accuracy: 0.000_001)
    }

    func testScannerAppliesLongContextTierFromLastUsage() throws {
        let now = try date("2026-07-14T04:00:00Z")
        let file = temporaryDirectory.appendingPathComponent("rollout-long-context.jsonl")
        try writeEvents([
            sessionMeta(id: "session-a", timestamp: "2026-07-14T00:00:00Z"),
            turnContext(model: "gpt-5.6-sol", timestamp: "2026-07-14T00:00:30Z"),
            tokenCount(
                input: 300_000,
                output: 10_000,
                total: 310_000,
                lastInput: 300_000,
                timestamp: "2026-07-14T00:01:00Z"
            ),
        ], to: file, modifiedAt: now)

        let snapshot = try scanner(now: { now }).snapshot()

        XCTAssertEqual(try XCTUnwrap(snapshot.todayCost?.estimatedCostUSD), 2.70, accuracy: 0.000_001)
    }

    func testDailyCostResetsWhileWeeklyEstimateUsesPostBaselineDelta() throws {
        let clock = TestClock(try date("2026-07-13T15:30:00Z"))
        let file = temporaryDirectory.appendingPathComponent("rollout-weekly-cost.jsonl")
        try writeEvents([
            sessionMeta(id: "session-a", timestamp: "2026-07-13T14:00:00Z"),
            turnContext(model: "gpt-5.6-luna", timestamp: "2026-07-13T14:30:00Z"),
            tokenCount(input: 1_000_000, total: 1_000_000, timestamp: "2026-07-13T15:00:00Z"),
        ], to: file, modifiedAt: clock.now)
        let scanner = scanner(now: { clock.now })
        let firstWindow = try rateLimitWindow(
            usedPercent: 10,
            end: "2026-07-20T00:00:00Z"
        )

        let firstDay = try scanner.snapshot(weeklyWindow: firstWindow)
        XCTAssertEqual(firstDay.localDate, "2026-07-13")
        XCTAssertEqual(firstDay.totalTokens, 1_000_000)
        XCTAssertEqual(firstDay.weeklyQuotaCost?.baselineUsedPercent, 10)
        XCTAssertEqual(firstDay.weeklyQuotaCost?.usedDeltaPercent, 0)
        XCTAssertNil(firstDay.weeklyQuotaCost?.estimatedQuotaUSD)

        clock.now = try date("2026-07-13T17:00:00Z")
        try appendEvent(
            tokenCount(input: 1_500_000, total: 1_500_000, timestamp: "2026-07-13T16:30:00Z"),
            to: file,
            modifiedAt: clock.now
        )
        let secondWindow = try rateLimitWindow(
            usedPercent: 20,
            end: "2026-07-20T00:00:00Z"
        )
        let snapshot = try scanner.snapshot(weeklyWindow: secondWindow)

        XCTAssertEqual(snapshot.localDate, "2026-07-14")
        XCTAssertEqual(snapshot.totalTokens, 500_000)
        XCTAssertEqual(try XCTUnwrap(snapshot.todayCost?.estimatedCostUSD), 0.10, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.weeklyQuotaCost?.usedDeltaPercent, 10)
        XCTAssertEqual(try XCTUnwrap(snapshot.weeklyQuotaCost?.observedCostUSD), 0.10, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(snapshot.weeklyQuotaCost?.estimatedQuotaUSD), 1.00, accuracy: 0.000_001)
    }

    func testWeeklyQuotaEstimateWaitsForEnoughPercentageSignal() throws {
        let clock = TestClock(try date("2026-07-14T04:00:00Z"))
        let file = temporaryDirectory.appendingPathComponent("rollout-early-week.jsonl")
        try writeEvents([
            sessionMeta(id: "session-a", timestamp: "2026-07-14T03:55:00Z"),
            turnContext(model: "gpt-5.6-luna", timestamp: "2026-07-14T03:56:00Z"),
        ], to: file, modifiedAt: clock.now)
        let scanner = scanner(now: { clock.now })
        let baselineWindow = try rateLimitWindow(
            usedPercent: 1,
            end: "2026-07-20T00:00:00Z"
        )
        _ = try scanner.snapshot(weeklyWindow: baselineWindow)

        clock.now = try date("2026-07-14T04:10:00Z")
        try appendEvent(
            tokenCount(input: 1_000_000, total: 1_000_000, timestamp: "2026-07-14T04:05:00Z"),
            to: file,
            modifiedAt: clock.now
        )
        let updatedWindow = try rateLimitWindow(
            usedPercent: 2,
            end: "2026-07-20T00:00:00Z"
        )
        let estimate = try scanner.snapshot(weeklyWindow: updatedWindow).weeklyQuotaCost

        XCTAssertEqual(try XCTUnwrap(estimate?.observedCostUSD), 0.20, accuracy: 0.000_001)
        XCTAssertEqual(estimate?.usedDeltaPercent, 1)
        XCTAssertNil(estimate?.estimatedQuotaUSD)
    }

    func testWeeklyQuotaEstimateRequiresKnownPriceCoverage() throws {
        let clock = TestClock(try date("2026-07-14T04:00:00Z"))
        let file = temporaryDirectory.appendingPathComponent("rollout-price-coverage.jsonl")
        try writeEvents([
            sessionMeta(id: "session-a", timestamp: "2026-07-14T03:55:00Z"),
            turnContext(model: "gpt-5.6-luna", timestamp: "2026-07-14T03:56:00Z"),
        ], to: file, modifiedAt: clock.now)
        let scanner = scanner(now: { clock.now })
        let baselineWindow = try rateLimitWindow(
            usedPercent: 10,
            end: "2026-07-20T00:00:00Z"
        )
        _ = try scanner.snapshot(weeklyWindow: baselineWindow)

        clock.now = try date("2026-07-14T04:10:00Z")
        try appendEvent(
            tokenCount(input: 1_000_000, total: 1_000_000, timestamp: "2026-07-14T04:02:00Z"),
            to: file,
            modifiedAt: clock.now
        )
        try appendEvent(
            turnContext(model: "community-model", timestamp: "2026-07-14T04:03:00Z"),
            to: file,
            modifiedAt: clock.now
        )
        try appendEvent(
            tokenCount(input: 2_000_000, total: 2_000_000, timestamp: "2026-07-14T04:04:00Z"),
            to: file,
            modifiedAt: clock.now
        )
        let updatedWindow = try rateLimitWindow(
            usedPercent: 12,
            end: "2026-07-20T00:00:00Z"
        )

        let estimate = try scanner.snapshot(weeklyWindow: updatedWindow).weeklyQuotaCost

        XCTAssertEqual(estimate?.coveragePercent, 50)
        XCTAssertEqual(estimate?.usedDeltaPercent, 2)
        XCTAssertEqual(try XCTUnwrap(estimate?.observedCostUSD), 0.20, accuracy: 0.000_001)
        XCTAssertNil(estimate?.estimatedQuotaUSD)
    }

    func testColdScanDoesNotBackfillUnmodifiedWeeklyFiles() throws {
        let now = try date("2026-07-14T04:00:00Z")
        let oldFile = temporaryDirectory.appendingPathComponent("rollout-old-weekly.jsonl")
        try writeEvents([
            sessionMeta(id: "session-a", timestamp: "2026-07-13T12:00:00Z"),
            turnContext(model: "gpt-5.6-luna", timestamp: "2026-07-13T12:01:00Z"),
            tokenCount(input: 1_000_000, total: 1_000_000, timestamp: "2026-07-13T12:02:00Z"),
        ], to: oldFile, modifiedAt: try date("2026-07-13T12:03:00Z"))
        let weeklyWindow = try rateLimitWindow(
            usedPercent: 20,
            end: "2026-07-20T00:00:00Z"
        )

        let snapshot = try scanner(now: { now }).snapshot(weeklyWindow: weeklyWindow)

        XCTAssertEqual(snapshot.filesScanned, 0)
        XCTAssertEqual(snapshot.totalTokens, 0)
        XCTAssertEqual(snapshot.weeklyQuotaCost?.observedCostUSD, 0)
        XCTAssertNil(snapshot.weeklyQuotaCost?.estimatedQuotaUSD)
    }

    func testRegressionDoesNotRecountWholeSession() throws {
        let now = try date("2026-07-14T04:00:00Z")
        let file = temporaryDirectory.appendingPathComponent("rollout-regression.jsonl")
        try writeEvents([
            sessionMeta(id: "session-a", timestamp: "2026-07-14T00:00:00Z"),
            tokenCount(total: 100, timestamp: "2026-07-14T00:01:00Z"),
            tokenCount(total: 90, timestamp: "2026-07-14T00:02:00Z"),
            tokenCount(total: 110, timestamp: "2026-07-14T00:03:00Z"),
        ], to: file, modifiedAt: now)

        let snapshot = try scanner(now: { now }).snapshot()

        XCTAssertEqual(snapshot.totalTokens, 110)
        XCTAssertEqual(snapshot.eventCount, 3)
        XCTAssertEqual(snapshot.duplicateEventCount, 1)
        XCTAssertEqual(snapshot.regressionEventCount, 1)
    }

    func testIncompleteLineIsProcessedAfterNextIncrementalRead() throws {
        let now = try date("2026-07-14T04:00:00Z")
        let file = temporaryDirectory.appendingPathComponent("rollout-partial.jsonl")
        var initialData = try jsonData(sessionMeta(id: "session-a", timestamp: "2026-07-14T00:00:00Z"))
        initialData.append(0x0A)
        initialData.append(try jsonData(tokenCount(total: 100, timestamp: "2026-07-14T00:01:00Z")))
        try initialData.write(to: file)
        try setModificationDate(now, for: file)
        let scanner = scanner(now: { now })

        XCTAssertEqual(try scanner.snapshot().totalTokens, 0)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x0A]))
        try handle.close()
        try setModificationDate(now, for: file)

        let completedSnapshot = try scanner.snapshot()
        XCTAssertEqual(completedSnapshot.totalTokens, 100)
        XCTAssertEqual(completedSnapshot.eventCount, 1)
    }

    func testPersistentCacheSurvivesProcessRestart() throws {
        let now = try date("2026-07-14T04:00:00Z")
        let file = temporaryDirectory.appendingPathComponent("rollout-persisted.jsonl")
        let cacheFile = temporaryDirectory.appendingPathComponent("local-usage-cache.json")
        try writeEvents([
            sessionMeta(id: "session-a", timestamp: "2026-07-14T00:00:00Z"),
            tokenCount(total: 100, timestamp: "2026-07-14T00:01:00Z"),
        ], to: file, modifiedAt: now)

        let firstScanner = CodexBackend.LocalUsageScanner(
            rootURLs: [temporaryDirectory],
            calendar: calendar,
            now: { now },
            cacheFileURL: cacheFile
        )
        XCTAssertEqual(try firstScanner.snapshot().totalTokens, 100)

        let originalSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        ).intValue
        var replacement = Data(repeating: 0x23, count: originalSize)
        replacement[replacement.index(before: replacement.endIndex)] = 0x0A
        try replacement.write(to: file)
        try setModificationDate(now, for: file)

        let restartedScanner = CodexBackend.LocalUsageScanner(
            rootURLs: [temporaryDirectory],
            calendar: calendar,
            now: { now },
            cacheFileURL: cacheFile
        )
        let restored = try restartedScanner.snapshot()

        XCTAssertEqual(restored.totalTokens, 100)
        XCTAssertEqual(restored.eventCount, 1)
    }

    func testPersistentCacheCarriesBaselineAcrossMidnightAndRestart() throws {
        let clock = TestClock(try date("2026-07-13T15:30:00Z"))
        let file = temporaryDirectory.appendingPathComponent("rollout-persisted-midnight.jsonl")
        let cacheFile = temporaryDirectory.appendingPathComponent("local-usage-cache.json")
        try writeEvents([
            sessionMeta(id: "session-a", timestamp: "2026-07-13T14:00:00Z"),
            turnContext(model: "gpt-5.6-luna", timestamp: "2026-07-13T14:30:00Z"),
            tokenCount(total: 100, timestamp: "2026-07-13T15:00:00Z"),
        ], to: file, modifiedAt: clock.now)

        let firstScanner = CodexBackend.LocalUsageScanner(
            rootURLs: [temporaryDirectory],
            calendar: calendar,
            now: { clock.now },
            cacheFileURL: cacheFile
        )
        let firstWindow = try rateLimitWindow(
            usedPercent: 10,
            end: "2026-07-20T00:00:00Z"
        )
        let firstDay = try firstScanner.snapshot(weeklyWindow: firstWindow)
        XCTAssertEqual(firstDay.totalTokens, 100)
        XCTAssertEqual(try XCTUnwrap(firstDay.todayCost?.estimatedCostUSD), 0.000_02, accuracy: 0.000_000_001)

        clock.now = try date("2026-07-13T17:00:00Z")
        try appendEvent(
            tokenCount(total: 150, timestamp: "2026-07-13T16:30:00Z"),
            to: file,
            modifiedAt: clock.now
        )
        let nextDayScanner = CodexBackend.LocalUsageScanner(
            rootURLs: [temporaryDirectory],
            calendar: calendar,
            now: { clock.now },
            cacheFileURL: cacheFile
        )
        let weeklyWindow = try rateLimitWindow(
            usedPercent: 20,
            end: "2026-07-20T00:00:00Z"
        )
        let nextDay = try nextDayScanner.snapshot(weeklyWindow: weeklyWindow)

        XCTAssertEqual(nextDay.localDate, "2026-07-14")
        XCTAssertEqual(nextDay.totalTokens, 50)
        XCTAssertEqual(nextDay.eventCount, 1)
        XCTAssertEqual(try XCTUnwrap(nextDay.todayCost?.estimatedCostUSD), 0.000_01, accuracy: 0.000_000_001)
        XCTAssertEqual(nextDay.weeklyQuotaCost?.usedDeltaPercent, 10)
        XCTAssertEqual(try XCTUnwrap(nextDay.weeklyQuotaCost?.observedCostUSD), 0.000_01, accuracy: 0.000_000_001)
        XCTAssertEqual(try XCTUnwrap(nextDay.weeklyQuotaCost?.estimatedQuotaUSD), 0.000_10, accuracy: 0.000_000_001)
    }

    func testNewModelPriceRebuildsDailyAndWeeklyCostWithoutResettingObservation() throws {
        let clock = TestClock(try date("2026-09-04T14:30:00Z"))
        let file = temporaryDirectory.appendingPathComponent("rollout-new-price.jsonl")
        let cacheFile = temporaryDirectory.appendingPathComponent("local-usage-cache.json")
        try writeEvents([
            sessionMeta(id: "session-a", timestamp: "2026-09-04T14:00:00Z"),
            turnContext(model: "gpt-5.6-sol", timestamp: "2026-09-04T14:01:00Z"),
            tokenCount(total: 1_000_000, timestamp: "2026-09-04T14:10:00Z"),
        ], to: file, modifiedAt: clock.now)
        let scanner = CodexBackend.LocalUsageScanner(
            rootURLs: [temporaryDirectory], calendar: calendar, now: { clock.now }, cacheFileURL: cacheFile
        )
        let first = try scanner.snapshot(weeklyWindow: rateLimitWindow(usedPercent: 10, end: "2026-09-07T00:00:00Z"))
        clock.now = try date("2026-09-04T15:30:00Z")
        try appendEvent(turnContext(model: "gpt-6-astra", timestamp: "2026-09-04T14:40:00Z"), to: file, modifiedAt: clock.now)
        try appendEvent(tokenCount(input: 1_100_000, output: 10_000, total: 1_110_000, lastInput: 300_000,
                                   timestamp: "2026-09-04T15:00:00Z"), to: file, modifiedAt: clock.now)
        let window = try rateLimitWindow(usedPercent: 12, end: "2026-09-07T00:00:00Z")
        _ = try scanner.snapshot(weeklyWindow: window)
        try removeCachedCost(model: "gpt-6-astra", from: cacheFile)

        clock.now = try date("2026-09-04T15:40:00Z")
        try appendEvent(tokenCount(input: 1_200_000, output: 20_000, total: 1_220_000, lastInput: 200_000,
                                   timestamp: "2026-09-04T15:35:00Z"), to: file, modifiedAt: clock.now)
        let rebuilt = try scanner.snapshot(weeklyWindow: window)
        XCTAssertEqual(rebuilt.totalTokens, 1_220_000)
        XCTAssertEqual(rebuilt.eventCount, 3)
        XCTAssertEqual(rebuilt.todayCost?.coveragePercent, 100)
        XCTAssertEqual(try XCTUnwrap(rebuilt.todayCost?.estimatedCostUSD), 8.25, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(rebuilt.weeklyQuotaCost?.observedCostUSD), 4.25, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(rebuilt.weeklyQuotaCost?.estimatedQuotaUSD), 212.5, accuracy: 0.000_001)
        XCTAssertEqual(rebuilt.weeklyQuotaCost?.observationStartIso, first.weeklyQuotaCost?.observationStartIso)
        XCTAssertEqual(rebuilt.weeklyQuotaCost?.baselineUsedPercent, 10)

        let inode = try FileManager.default.attributesOfItem(atPath: cacheFile.path)[.systemFileNumber] as? NSNumber
        let again = try scanner.snapshot(weeklyWindow: window)
        XCTAssertEqual(again.todayCost?.estimatedCostUSD, rebuilt.todayCost?.estimatedCostUSD)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: cacheFile.path)[.systemFileNumber] as? NSNumber, inode)
    }

    func testNewModelPriceRebuildsUnmodifiedWeeklyFileAfterMidnightAndRestart() throws {
        let clock = TestClock(try date("2026-09-04T14:30:00Z"))
        let file = temporaryDirectory.appendingPathComponent("rollout-weekly-reprice.jsonl")
        let cacheFile = temporaryDirectory.appendingPathComponent("local-usage-cache.json")
        try writeEvents([
            sessionMeta(id: "session-a", timestamp: "2026-09-04T14:00:00Z"),
            turnContext(model: "gpt-6-astra", timestamp: "2026-09-04T14:01:00Z"),
        ], to: file, modifiedAt: clock.now)
        let scanner = CodexBackend.LocalUsageScanner(
            rootURLs: [temporaryDirectory], calendar: calendar, now: { clock.now }, cacheFileURL: cacheFile
        )
        let first = try scanner.snapshot(weeklyWindow: rateLimitWindow(usedPercent: 10, end: "2026-09-07T00:00:00Z"))
        clock.now = try date("2026-09-04T15:30:00Z")
        try appendEvent(tokenCount(input: 100_000, output: 10_000, total: 110_000, lastInput: 300_000,
                                   timestamp: "2026-09-04T15:00:00Z"), to: file, modifiedAt: clock.now)
        let window = try rateLimitWindow(usedPercent: 12, end: "2026-09-07T00:00:00Z")
        _ = try scanner.snapshot(weeklyWindow: window)
        try removeCachedCost(model: "gpt-6-astra", from: cacheFile)

        clock.now = try date("2026-09-05T01:00:00Z")
        let restarted = CodexBackend.LocalUsageScanner(
            rootURLs: [temporaryDirectory], calendar: calendar, now: { clock.now }, cacheFileURL: cacheFile
        )
        let rebuilt = try restarted.snapshot(weeklyWindow: window)
        XCTAssertEqual(rebuilt.localDate, "2026-09-05")
        XCTAssertEqual(rebuilt.totalTokens, 0)
        XCTAssertEqual(rebuilt.todayCost?.estimatedCostUSD, 0)
        XCTAssertEqual(rebuilt.weeklyQuotaCost?.coveragePercent, 100)
        XCTAssertEqual(try XCTUnwrap(rebuilt.weeklyQuotaCost?.observedCostUSD), 2.75, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(rebuilt.weeklyQuotaCost?.estimatedQuotaUSD), 137.5, accuracy: 0.000_001)
        XCTAssertEqual(rebuilt.weeklyQuotaCost?.observationStartIso, first.weeklyQuotaCost?.observationStartIso)
    }

    func testNewModelPriceKeepsMissingLogsUnpricedUntilRestored() throws {
        let now = try date("2026-09-05T01:00:00Z")
        let file = temporaryDirectory.appendingPathComponent("rollout-missing-price.jsonl")
        let cacheFile = temporaryDirectory.appendingPathComponent("local-usage-cache.json")
        try writeEvents([
            sessionMeta(id: "session-a", timestamp: "2026-09-05T00:00:00Z"),
            turnContext(model: "gpt-6-astra", timestamp: "2026-09-05T00:01:00Z"),
            tokenCount(total: 100_000, timestamp: "2026-09-05T00:10:00Z"),
        ], to: file, modifiedAt: now)
        let scanner = CodexBackend.LocalUsageScanner(
            rootURLs: [temporaryDirectory], calendar: calendar, now: { now }, cacheFileURL: cacheFile
        )
        _ = try scanner.snapshot()
        try removeCachedCost(model: "gpt-6-astra", from: cacheFile)
        let logData = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        let missing = try scanner.snapshot()
        XCTAssertEqual(missing.totalTokens, 100_000)
        XCTAssertEqual(missing.todayCost?.coveragePercent, 0)
        XCTAssertNil(missing.todayCost?.estimatedCostUSD)

        try logData.write(to: file)
        try setModificationDate(now, for: file)
        let restored = try scanner.snapshot()
        XCTAssertEqual(restored.totalTokens, 100_000)
        XCTAssertEqual(restored.todayCost?.estimatedCostUSD, 1.0)
        XCTAssertEqual(restored.todayCost?.coveragePercent, 100)
    }

    func testPersistentCacheAggregatesCostWithoutRetainingEveryEvent() throws {
        let now = try date("2026-07-14T04:00:00Z")
        let file = temporaryDirectory.appendingPathComponent("rollout-compact-cache.jsonl")
        let cacheFile = temporaryDirectory.appendingPathComponent("local-usage-cache.json")
        var events = [
            sessionMeta(id: "session-a", timestamp: "2026-07-14T00:00:00Z"),
            turnContext(model: "gpt-5.6-luna", timestamp: "2026-07-14T00:00:01Z"),
        ]
        for index in 1...1_000 {
            events.append(tokenCount(
                total: Int64(index * 100),
                timestamp: String(format: "2026-07-14T00:%02d:%02dZ", (index / 60) % 60, index % 60)
            ))
        }
        try writeEvents(events, to: file, modifiedAt: now)

        let scanner = CodexBackend.LocalUsageScanner(
            rootURLs: [temporaryDirectory],
            calendar: calendar,
            now: { now },
            cacheFileURL: cacheFile
        )
        let snapshot = try scanner.snapshot()
        let cacheData = try Data(contentsOf: cacheFile)
        let cacheText = try XCTUnwrap(String(data: cacheData, encoding: .utf8))

        XCTAssertEqual(snapshot.totalTokens, 100_000)
        XCTAssertEqual(try XCTUnwrap(snapshot.todayCost?.estimatedCostUSD), 0.02, accuracy: 0.000_001)
        XCTAssertFalse(cacheText.contains("costEvents"))
        XCTAssertLessThan(cacheData.count, 20_000)

        let restartedScanner = CodexBackend.LocalUsageScanner(
            rootURLs: [temporaryDirectory],
            calendar: calendar,
            now: { now },
            cacheFileURL: cacheFile
        )
        let restored = try restartedScanner.snapshot()
        XCTAssertEqual(restored.totalTokens, snapshot.totalTokens)
        XCTAssertEqual(restored.todayCost?.estimatedCostUSD, snapshot.todayCost?.estimatedCostUSD)
    }

    func testLargeIrrelevantLineAcrossReadChunksIsSkipped() throws {
        let now = try date("2026-07-14T04:00:00Z")
        let file = temporaryDirectory.appendingPathComponent("rollout-large-line.jsonl")
        var data = try jsonData(sessionMeta(id: "session-a", timestamp: "2026-07-14T00:00:00Z"))
        data.append(0x0A)
        data.append(Data("{\"timestamp\":\"2026-07-14T00:00:30Z\",\"type\":\"response_item\",\"payload\":{\"text\":\"".utf8))
        data.append(Data(repeating: 0x78, count: 5 * 1_024 * 1_024))
        data.append(Data("\"}}\n".utf8))
        data.append(try jsonData(tokenCount(total: 100, timestamp: "2026-07-14T00:01:00Z")))
        data.append(0x0A)
        try data.write(to: file)
        try setModificationDate(now, for: file)

        let snapshot = try scanner(now: { now }).snapshot()

        XCTAssertEqual(snapshot.totalTokens, 100)
        XCTAssertEqual(snapshot.eventCount, 1)
        XCTAssertEqual(snapshot.parseErrorCount, 0)
    }

    func testOversizedIncompleteLineIsSkippedAcrossIncrementalReads() throws {
        let now = try date("2026-07-14T04:00:00Z")
        let file = temporaryDirectory.appendingPathComponent("rollout-oversized-partial.jsonl")
        var data = try jsonData(sessionMeta(id: "session-a", timestamp: "2026-07-14T00:00:00Z"))
        data.append(0x0A)
        data.append(Data("{\"timestamp\":\"2026-07-14T00:00:30Z\",\"type\":\"response_item\",\"payload\":{\"text\":\"".utf8))
        data.append(Data(repeating: 0x78, count: 2 * 1_024 * 1_024))
        try data.write(to: file)
        try setModificationDate(now, for: file)
        let scanner = scanner(now: { now })

        XCTAssertEqual(try scanner.snapshot().totalTokens, 0)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\"}}\n".utf8))
        try handle.write(contentsOf: jsonData(tokenCount(total: 100, timestamp: "2026-07-14T00:01:00Z")))
        try handle.write(contentsOf: Data([0x0A]))
        try handle.close()
        try setModificationDate(now, for: file)

        let snapshot = try scanner.snapshot()

        XCTAssertEqual(snapshot.totalTokens, 100)
        XCTAssertEqual(snapshot.eventCount, 1)
        XCTAssertEqual(snapshot.parseErrorCount, 0)
    }

    func testServiceTierSwitchesSurviveIncrementalReadsAndRestart() throws {
        let now = try date("2026-09-11T04:00:00Z")
        let file = temporaryDirectory.appendingPathComponent("rollout-tiers.jsonl")
        let cache = temporaryDirectory.appendingPathComponent("cache.json")
        var fast = turnContext(model: "gpt-6-astra", timestamp: "2026-09-11T00:00:30Z")
        fast["payload"] = ["model": "gpt-6-astra", "service_tier": "fast"]
        try writeEvents([
            sessionMeta(id: "a", timestamp: "2026-09-11T00:00:00Z"), fast,
            tokenCount(input: 1_000_000, total: 1_000_000, lastInput: 100_000, timestamp: "2026-09-11T00:01:00Z"),
        ], to: file, modifiedAt: now)
        let first = CodexBackend.LocalUsageScanner(rootURLs: [temporaryDirectory], calendar: calendar,
                                                   now: { now }, cacheFileURL: cache)
        XCTAssertEqual(try first.snapshot().todayCredits?.estimatedCredits, 625)
        try appendEvent(tokenCount(input: 2_000_000, total: 2_000_000, lastInput: 100_000,
                                   timestamp: "2026-09-11T00:02:00Z"), to: file, modifiedAt: now)
        let restarted = CodexBackend.LocalUsageScanner(rootURLs: [temporaryDirectory], calendar: calendar,
                                                       now: { now }, cacheFileURL: cache)
        XCTAssertEqual(try restarted.snapshot().todayCredits?.estimatedCredits, 1_250)
        try appendEvent(turnContext(model: "gpt-6-astra", timestamp: "2026-09-11T00:03:00Z"), to: file, modifiedAt: now)
        try appendEvent(tokenCount(input: 3_000_000, total: 3_000_000, lastInput: 100_000,
                                   timestamp: "2026-09-11T00:04:00Z"), to: file, modifiedAt: now)
        let standard = try restarted.snapshot()
        XCTAssertEqual(standard.todayCredits?.estimatedCredits, 1_500)
        XCTAssertEqual(standard.todayCredits?.assumedStandardTokens, 1_000_000)
        XCTAssertEqual(standard.todayCost?.estimatedCostUSD, 30)
        XCTAssertEqual(try restarted.snapshot().todayCredits?.estimatedCredits, 1_500)
        try appendEvent(["timestamp": "2026-09-11T00:05:00Z", "type": "event_msg",
                         "payload": ["type": "thread_settings_applied", "settings": ["service_tier": "fast"]]],
                        to: file, modifiedAt: now)
        try appendEvent(tokenCount(total: 4_000_000, timestamp: "2026-09-11T00:06:00Z"), to: file, modifiedAt: now)
        try appendEvent(["timestamp": "2026-09-11T00:07:00Z", "type": "event_msg",
                         "payload": ["type": "thread_settings_applied", "settings": ["service_tier": NSNull()]]],
                        to: file, modifiedAt: now)
        try appendEvent(tokenCount(total: 5_000_000, timestamp: "2026-09-11T00:08:00Z"), to: file, modifiedAt: now)
        XCTAssertEqual(try restarted.snapshot().todayCredits?.estimatedCredits, 2_375)
    }

    func testLegacyMisidentifiedModelIsReplayedWithoutResettingWeeklyBaseline() throws {
        let clock = TestClock(try date("2026-09-11T01:00:00Z"))
        let file = temporaryDirectory.appendingPathComponent("rollout-legacy.jsonl")
        let cacheFile = temporaryDirectory.appendingPathComponent("cache.json")
        try writeEvents([sessionMeta(id: "a", timestamp: "2026-09-11T00:00:00Z"),
                         turnContext(model: "gpt-5.3-codex-spark", timestamp: "2026-09-11T00:01:00Z")],
                        to: file, modifiedAt: clock.now)
        let scanner = CodexBackend.LocalUsageScanner(rootURLs: [temporaryDirectory], calendar: calendar,
                                                     now: { clock.now }, cacheFileURL: cacheFile)
        let baseline = try scanner.snapshot(weeklyWindow: rateLimitWindow(usedPercent: 10, end: "2026-09-14T00:00:00Z"))
        clock.now = try date("2026-09-11T02:00:00Z")
        try appendEvent(tokenCount(total: 100_000, timestamp: "2026-09-11T01:30:00Z"), to: file, modifiedAt: clock.now)
        let window = try rateLimitWindow(usedPercent: 12, end: "2026-09-14T00:00:00Z")
        _ = try scanner.snapshot(weeklyWindow: window)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheFile)) as? [String: Any])
        var cache = try XCTUnwrap(document["cache"] as? [String: Any])
        var files = try XCTUnwrap(cache["files"] as? [String: [String: Any]])
        let cachePath = try XCTUnwrap(files.keys.first { URL(fileURLWithPath: $0).lastPathComponent == file.lastPathComponent })
        var state = try XCTUnwrap(files[cachePath])
        for key in ["dailyCost", "weeklyCost"] {
            var cost = try XCTUnwrap(state[key] as? [String: Any])
            let buckets = try XCTUnwrap(cost["buckets"] as? [String: [String: Any]])
            var bucket = try XCTUnwrap(buckets["gpt-5.3-codex-spark"])
            bucket.removeValue(forKey: "pricingSignature")
            bucket.removeValue(forKey: "credits")
            bucket["estimatedCostUSD"] = 12345.0
            cost["buckets"] = ["gpt-5.3-codex": bucket]
            state[key] = cost
        }
        files[cachePath] = state; cache["files"] = files; document["cache"] = cache
        try JSONSerialization.data(withJSONObject: document).write(to: cacheFile, options: .atomic)
        let log = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        let missing = try scanner.snapshot(weeklyWindow: window)
        XCTAssertEqual(missing.todayCost?.coveragePercent, 0)
        XCTAssertNil(missing.todayCost?.estimatedCostUSD)
        try log.write(to: file)
        try setModificationDate(clock.now, for: file)
        let repaired = try scanner.snapshot(weeklyWindow: window)
        XCTAssertEqual(repaired.totalTokens, 100_000)
        XCTAssertEqual(repaired.todayCost?.unpricedModels, ["gpt-5.3-codex-spark"])
        XCTAssertNil(repaired.weeklyQuotaCost?.estimatedQuotaUSD)
        XCTAssertEqual(repaired.weeklyQuotaCost?.observationStartIso, baseline.weeklyQuotaCost?.observationStartIso)
        XCTAssertEqual(repaired.weeklyQuotaCost?.baselineUsedPercent, 10)
        XCTAssertEqual(repaired.weeklyQuotaCost?.unpricedModels, ["gpt-5.3-codex-spark"])
        let persisted = try Data(contentsOf: cacheFile)
        _ = try scanner.snapshot(weeklyWindow: window)
        XCTAssertEqual(try Data(contentsOf: cacheFile), persisted)
    }

    func testAddingRootsKeepsObservationAndDeduplicatesCopies() throws {
        let clock = TestClock(try date("2026-09-11T01:00:00Z"))
        let firstRoot = temporaryDirectory.appendingPathComponent("desktop")
        let secondRoot = temporaryDirectory.appendingPathComponent("cli")
        for root in [firstRoot, secondRoot] { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let file = firstRoot.appendingPathComponent("rollout-a.jsonl")
        let cache = temporaryDirectory.appendingPathComponent("cache.json")
        try writeEvents([sessionMeta(id: "a", timestamp: "2026-09-11T00:00:00Z"),
                         turnContext(model: "gpt-5.6-sol", timestamp: "2026-09-11T00:01:00Z")], to: file, modifiedAt: clock.now)
        let first = CodexBackend.LocalUsageScanner(rootURLs: [firstRoot], calendar: calendar, now: { clock.now }, cacheFileURL: cache)
        let baseline = try first.snapshot(weeklyWindow: rateLimitWindow(usedPercent: 10, end: "2026-09-14T00:00:00Z"))
        clock.now = try date("2026-09-11T02:00:00Z")
        try appendEvent(tokenCount(total: 1_000_000, timestamp: "2026-09-11T01:30:00Z"), to: file, modifiedAt: clock.now)
        try FileManager.default.copyItem(at: file, to: secondRoot.appendingPathComponent(file.lastPathComponent))
        try writeEvents([sessionMeta(id: "b", timestamp: "2026-09-11T01:00:00Z"),
                         turnContext(model: "gpt-5.6-luna", timestamp: "2026-09-11T01:01:00Z"),
                         tokenCount(total: 1_000_000, timestamp: "2026-09-11T01:30:00Z")],
                        to: secondRoot.appendingPathComponent("rollout-b.jsonl"), modifiedAt: clock.now)
        let expanded = CodexBackend.LocalUsageScanner(rootURLs: [firstRoot, secondRoot], calendar: calendar,
                                                     now: { clock.now }, cacheFileURL: cache)
        let result = try expanded.snapshot(weeklyWindow: rateLimitWindow(usedPercent: 12, end: "2026-09-14T00:00:00Z"))
        XCTAssertEqual(result.totalTokens, 2_000_000)
        XCTAssertEqual(result.todayCost?.estimatedCostUSD, 4.2)
        XCTAssertEqual(result.todayCredits?.estimatedCredits, 105)
        XCTAssertEqual(result.weeklyQuotaCost?.observationStartIso, baseline.weeklyQuotaCost?.observationStartIso)
        XCTAssertEqual(result.weeklyQuotaCost?.baselineUsedPercent, 10)
    }

    func testWeeklyCostExcludesAnotherCodexHome() throws {
        let clock = TestClock(try date("2026-09-11T01:00:00Z"))
        let desktop = temporaryDirectory.appendingPathComponent("desktop")
        let cli = temporaryDirectory.appendingPathComponent("cli")
        for root in [desktop, cli] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try writeEvents([sessionMeta(id: root.lastPathComponent, timestamp: "2026-09-11T00:00:00Z"),
                             turnContext(model: "gpt-5.6-sol", timestamp: "2026-09-11T00:01:00Z")],
                            to: root.appendingPathComponent("rollout-\(root.lastPathComponent).jsonl"), modifiedAt: clock.now)
        }
        let scanner = CodexBackend.LocalUsageScanner(rootURLs: [desktop, cli], calendar: calendar,
                                                     now: { clock.now }, weeklyRootURLs: [desktop])
        _ = try scanner.snapshot(weeklyWindow: rateLimitWindow(usedPercent: 10, end: "2026-09-14T00:00:00Z"))
        clock.now = try date("2026-09-11T02:00:00Z")
        for root in [desktop, cli] {
            try appendEvent(tokenCount(total: 1_000_000, timestamp: "2026-09-11T01:30:00Z"),
                            to: root.appendingPathComponent("rollout-\(root.lastPathComponent).jsonl"), modifiedAt: clock.now)
        }
        let result = try scanner.snapshot(weeklyWindow: rateLimitWindow(usedPercent: 12, end: "2026-09-14T00:00:00Z"))
        XCTAssertEqual(result.totalTokens, 2_000_000)
        XCTAssertEqual(result.todayCost?.estimatedCostUSD, 8)
        XCTAssertEqual(result.todayCredits?.estimatedCredits, 200)
        XCTAssertEqual(result.weeklyQuotaCost?.observedCostUSD, 4)
        XCTAssertEqual(result.weeklyQuotaCost?.estimatedQuotaUSD, 200)
        XCTAssertEqual(result.weeklyQuotaCost?.source, desktop.resolvingSymlinksInPath().path)
    }

    func testRootDiscoveryHonorsOverridesAndDeduplicatesSymlinks() throws {
        let desktop = temporaryDirectory.appendingPathComponent(".codex/sessions")
        let cli = temporaryDirectory.appendingPathComponent(".codex-cli/sessions")
        let archive = temporaryDirectory.appendingPathComponent(".codex-cli/archived_sessions")
        for root in [desktop, cli, archive] { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let alias = temporaryDirectory.appendingPathComponent("custom-home")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: cli.deletingLastPathComponent())
        let roots = CodexBackend.localUsageRootURLs(environment: ["CODEX_HOME": alias.path], home: temporaryDirectory)
        XCTAssertEqual(Set(roots.map(\.path)), Set([desktop, cli, archive].map { $0.resolvingSymlinksInPath().path }))
        let override = CodexBackend.localUsageRootURLs(environment: ["CODEX_SESSIONS_DIR": desktop.path], home: temporaryDirectory)
        XCTAssertEqual(override, [desktop.resolvingSymlinksInPath()])
    }

    func testDifferentCodexHomesDoNotOverwriteEachOthersObservationCache() throws {
        let standard = try XCTUnwrap(CodexBackend.localUsageCacheURL(environment: [:], home: temporaryDirectory))
        let explicitDefault = CodexBackend.localUsageCacheURL(
            environment: ["CODEX_HOME": temporaryDirectory.appendingPathComponent(".codex").path], home: temporaryDirectory)
        let cli = CodexBackend.localUsageCacheURL(
            environment: ["CODEX_HOME": temporaryDirectory.appendingPathComponent(".codex-cli").path], home: temporaryDirectory)
        XCTAssertEqual(standard.lastPathComponent, "local-usage-cache.json")
        XCTAssertEqual(standard, explicitDefault)
        XCTAssertNotEqual(standard, cli)
        XCTAssertEqual(cli, CodexBackend.localUsageCacheURL(
            environment: ["CODEX_HOME": temporaryDirectory.appendingPathComponent(".codex-cli").path], home: temporaryDirectory))
        XCTAssertNil(CodexBackend.localUsageCacheURL(environment: ["CODEX_SESSIONS_DIR": temporaryDirectory.path], home: temporaryDirectory))
    }

    func testAccountSwitchResetsWeeklyObservationAndRetainsWholeMachineDailyUsage() throws {
        let clock = TestClock(try date("2026-09-11T01:00:00Z"))
        let file = temporaryDirectory.appendingPathComponent("rollout-account.jsonl")
        let cacheFile = temporaryDirectory.appendingPathComponent("usage-cache.json")
        try writeEvents([sessionMeta(id: "session-a", timestamp: "2026-09-11T00:00:00Z"),
                         turnContext(model: "gpt-5.6-sol", timestamp: "2026-09-11T00:01:00Z")], to: file, modifiedAt: clock.now)
        func context(_ key: String, limit: String = "codex") -> CodexAccountContext {
            CodexAccountContext(codexHome: temporaryDirectory.path, authenticationSource: "auth.json",
                                accountKey: key, accountLabel: nil, limitID: limit)
        }
        let scanner = CodexBackend.LocalUsageScanner(rootURLs: [temporaryDirectory], calendar: calendar,
                                                     now: { clock.now }, cacheFileURL: cacheFile)
        let a = context("a"), b = context("b")
        _ = try scanner.snapshot(weeklyWindow: rateLimitWindow(usedPercent: 10, end: "2026-09-17T00:00:00Z"), accountContext: a)
        clock.now = try date("2026-09-11T02:00:00Z")
        try appendEvent(tokenCount(total: 100_000, timestamp: "2026-09-11T01:30:00Z"), to: file, modifiedAt: clock.now)
        let first = try scanner.snapshot(weeklyWindow: rateLimitWindow(usedPercent: 15, end: "2026-09-17T00:00:00Z"), accountContext: a)
        XCTAssertEqual(first.weeklyQuotaCost?.observedCostUSD, 0.4)
        let restarted = CodexBackend.LocalUsageScanner(rootURLs: [temporaryDirectory], calendar: calendar,
                                                       now: { clock.now }, cacheFileURL: cacheFile)
        let resumed = try restarted.snapshot(weeklyWindow: rateLimitWindow(usedPercent: 15, end: "2026-09-17T00:00:00Z"), accountContext: a)
        XCTAssertEqual(resumed.weeklyQuotaCost?.observationStartIso, first.weeklyQuotaCost?.observationStartIso)
        XCTAssertEqual(resumed.weeklyQuotaCost?.observedCostUSD, 0.4)
        clock.now = try date("2026-09-11T03:00:00Z")
        let switched = try restarted.snapshot(weeklyWindow: rateLimitWindow(usedPercent: 40, end: "2026-09-17T00:00:00Z"), accountContext: b)
        XCTAssertEqual(switched.totalTokens, 100_000)
        XCTAssertEqual(switched.weeklyQuotaCost?.observedCostUSD, 0)
        XCTAssertEqual(switched.weeklyQuotaCost?.baselineUsedPercent, 40)
        XCTAssertEqual(switched.weeklyQuotaCost?.accountScopeKey, b.scopeKey)
        clock.now = try date("2026-09-11T04:00:00Z")
        try appendEvent(tokenCount(total: 150_000, timestamp: "2026-09-11T03:30:00Z"), to: file, modifiedAt: clock.now)
        let bUsage = try restarted.snapshot(weeklyWindow: rateLimitWindow(usedPercent: 45, end: "2026-09-17T00:00:00Z"), accountContext: b)
        XCTAssertEqual(bUsage.totalTokens, 150_000)
        XCTAssertEqual(bUsage.weeklyQuotaCost?.observedCostUSD, 0.2)
        let returned = try restarted.snapshot(weeklyWindow: rateLimitWindow(usedPercent: 20, end: "2026-09-17T00:00:00Z"), accountContext: a)
        XCTAssertEqual(returned.weeklyQuotaCost?.observedCostUSD, 0)
        XCTAssertEqual(returned.weeklyQuotaCost?.baselineUsedPercent, 20)
        let otherBucket = try restarted.snapshot(weeklyWindow: rateLimitWindow(usedPercent: 30, end: "2026-09-17T00:00:00Z"), accountContext: context("a", limit: "spark"))
        XCTAssertEqual(otherBucket.weeklyQuotaCost?.baselineUsedPercent, 30)
        XCTAssertEqual(otherBucket.totalTokens, 150_000)
    }

    func testUnattributedWeeklyCacheStartsNewObservationWithoutLosingDailyTotals() throws {
        let clock = TestClock(try date("2026-09-11T01:00:00Z"))
        let file = temporaryDirectory.appendingPathComponent("rollout-legacy-account.jsonl")
        try writeEvents([sessionMeta(id: "session-a", timestamp: "2026-09-11T00:00:00Z"),
                         turnContext(model: "gpt-5.6-sol", timestamp: "2026-09-11T00:01:00Z")], to: file, modifiedAt: clock.now)
        let scanner = self.scanner(now: { clock.now })
        _ = try scanner.snapshot(weeklyWindow: rateLimitWindow(usedPercent: 10, end: "2026-09-17T00:00:00Z"))
        clock.now = try date("2026-09-11T02:00:00Z")
        try appendEvent(tokenCount(total: 100_000, timestamp: "2026-09-11T01:30:00Z"), to: file, modifiedAt: clock.now)
        _ = try scanner.snapshot(weeklyWindow: rateLimitWindow(usedPercent: 15, end: "2026-09-17T00:00:00Z"))
        let context = CodexAccountContext(codexHome: temporaryDirectory.path, authenticationSource: "auth.json",
                                          accountKey: "a", accountLabel: nil, limitID: "codex")
        let migrated = try scanner.snapshot(weeklyWindow: rateLimitWindow(usedPercent: 15, end: "2026-09-17T00:00:00Z"), accountContext: context)
        XCTAssertEqual(migrated.totalTokens, 100_000)
        XCTAssertEqual(migrated.weeklyQuotaCost?.observedCostUSD, 0)
        XCTAssertEqual(migrated.weeklyQuotaCost?.baselineUsedPercent, 15)
        XCTAssertEqual(migrated.weeklyQuotaCost?.accountScopeKey, context.scopeKey)
        let invalidated = try scanner.snapshot(accountContext: context, invalidateWeeklyObservation: true)
        XCTAssertEqual(invalidated.totalTokens, 100_000)
        XCTAssertNil(invalidated.weeklyQuotaCost)
        clock.now = try date("2026-09-11T03:00:00Z")
        let resumed = try scanner.snapshot(weeklyWindow: rateLimitWindow(usedPercent: 20, end: "2026-09-17T00:00:00Z"), accountContext: context)
        XCTAssertEqual(resumed.weeklyQuotaCost?.baselineUsedPercent, 20)
    }

    private func scanner(now: @escaping () -> Date) -> CodexBackend.LocalUsageScanner {
        CodexBackend.LocalUsageScanner(rootURLs: [temporaryDirectory], calendar: calendar, now: now)
    }

    private func removeCachedCost(model: String, from url: URL) throws {
        let data = try Data(contentsOf: url)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var cache = try XCTUnwrap(document["cache"] as? [String: Any])
        var files = try XCTUnwrap(cache["files"] as? [String: [String: Any]])
        for (path, var state) in files {
            for key in ["dailyCost", "weeklyCost"] {
                guard var cost = state[key] as? [String: Any],
                      var buckets = cost["buckets"] as? [String: [String: Any]],
                      var bucket = buckets[model] else { continue }
                bucket.removeValue(forKey: "estimatedCostUSD")
                buckets[model] = bucket
                cost["buckets"] = buckets
                state[key] = cost
            }
            files[path] = state
        }
        cache["files"] = files
        document["cache"] = cache
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: url, options: .atomic)
    }

    private func sessionMeta(id: String, timestamp: String) -> [String: Any] {
        [
            "timestamp": timestamp,
            "type": "session_meta",
            "payload": ["id": id],
        ]
    }

    private func turnContext(model: String, timestamp: String) -> [String: Any] {
        [
            "timestamp": timestamp,
            "type": "turn_context",
            "payload": ["model": model],
        ]
    }

    private func tokenCount(total: Int64, timestamp: String) -> [String: Any] {
        tokenCount(input: total, total: total, timestamp: timestamp)
    }

    private func tokenCount(
        input: Int64,
        cachedInput: Int64 = 0,
        cacheWriteInput: Int64 = 0,
        output: Int64 = 0,
        reasoningOutput: Int64 = 0,
        total: Int64,
        lastInput: Int64? = nil,
        timestamp: String
    ) -> [String: Any] {
        var info: [String: Any] = [
            "total_token_usage": tokenUsage(
                input: input,
                cachedInput: cachedInput,
                cacheWriteInput: cacheWriteInput,
                output: output,
                reasoningOutput: reasoningOutput,
                total: total
            ),
        ]
        if let lastInput {
            info["last_token_usage"] = tokenUsage(input: lastInput, total: lastInput)
        }
        return [
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": info,
            ],
        ]
    }

    private func tokenUsage(
        input: Int64,
        cachedInput: Int64 = 0,
        cacheWriteInput: Int64 = 0,
        output: Int64 = 0,
        reasoningOutput: Int64 = 0,
        total: Int64
    ) -> [String: Any] {
        [
            "input_tokens": input,
            "cached_input_tokens": cachedInput,
            "cache_write_input_tokens": cacheWriteInput,
            "output_tokens": output,
            "reasoning_output_tokens": reasoningOutput,
            "total_tokens": total,
        ]
    }

    private func rateLimitWindow(usedPercent: Int, end: String) throws -> RateLimitWindow {
        let endDate = try date(end)
        return RateLimitWindow(
            usedPercent: usedPercent,
            remainingPercent: 100 - usedPercent,
            windowDurationMins: 10_080,
            resetsAt: Int(endDate.timeIntervalSince1970),
            resetsAtIso: ISO8601DateFormatter().string(from: endDate)
        )
    }

    private func writeEvents(_ events: [[String: Any]], to file: URL, modifiedAt: Date) throws {
        var data = Data()
        for event in events {
            data.append(try jsonData(event))
            data.append(0x0A)
        }
        try data.write(to: file)
        try setModificationDate(modifiedAt, for: file)
    }

    private func appendEvent(_ event: [String: Any], to file: URL, modifiedAt: Date) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: jsonData(event))
        try handle.write(contentsOf: Data([0x0A]))
        try handle.close()
        try setModificationDate(modifiedAt, for: file)
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func setModificationDate(_ date: Date, for file: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: value))
    }
}

private final class TestClock: @unchecked Sendable {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private final class TestCalendar: @unchecked Sendable {
    var value: Calendar

    init(_ value: Calendar) {
        self.value = value
    }
}
