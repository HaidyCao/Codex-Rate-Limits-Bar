import Foundation
import XCTest
@testable import CodexRateLimitsCore

final class CachePersistenceTests: XCTestCase {
    private var root: URL!
    private var now = ISO8601DateFormatter().date(from: "2026-09-12T08:00:00Z")!
    private var cacheURL: URL { root.appendingPathComponent("cache.json") }
    private var logURL: URL { root.appendingPathComponent("usage.jsonl") }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CachePersistence-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lines: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "persistence-fixture"]],
            ["type": "turn_context", "payload": ["model": "gpt-5.6-sol", "service_tier": "standard"]],
            event(total: 100, timestamp: "2026-09-12T07:59:00Z")]
        try lines.reduce(into: Data()) { data, line in
            data.append(try JSONSerialization.data(withJSONObject: line)); data.append(0x0A)
        }.write(to: logURL)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testFailedWriteIsVisibleAndRetriesWithoutNewLogData() throws {
        // A directory at the destination reliably rejects atomic replacement.
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: false)
        let scanner = scanner()
        let failed = try scanner.snapshot()
        XCTAssertEqual(failed.totalTokens, 100)
        XCTAssertEqual(failed.diagnostics?.status, .complete)
        XCTAssertNil(failed.error)
        XCTAssertEqual(RefreshOutcome.local(failed).phase, .success)
        XCTAssertNotNil(failed.persistence?.error)
        XCTAssertTrue(AppText.scanDetails(failed).contains(try XCTUnwrap(failed.persistence?.error)))
        XCTAssertEqual(try persistenceStatus(failed), "pending")
        XCTAssertEqual(try persistenceStatus(scanner.snapshot()), "pending")
        try FileManager.default.removeItem(at: cacheURL)
        let recovered = try scanner.snapshot()
        XCTAssertEqual(try persistenceStatus(recovered), "saved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
        XCTAssertEqual(recovered.totalTokens, 100)
        XCTAssertEqual(recovered.todayCost?.estimatedCostUSD, failed.todayCost?.estimatedCostUSD)
        XCTAssertNil(recovered.persistence?.error)
        XCTAssertEqual(try self.scanner().snapshot().totalTokens, 100)
    }

    func testFailedAppendRetriesAgainstOriginalDiskWithoutDoubleCounting() throws {
        let scanner = scanner()
        _ = try scanner.snapshot()
        let original = try Data(contentsOf: cacheURL)
        let saved = try obstructCache()
        try append(total: 200)
        XCTAssertEqual(try scanner.snapshot().persistence?.status, .pending)
        XCTAssertEqual(try scanner.snapshot().totalTokens, 200)
        try restoreCache(saved)
        XCTAssertEqual(try Data(contentsOf: cacheURL), original)
        let recovered = try scanner.snapshot()
        XCTAssertEqual(recovered.totalTokens, 200)
        XCTAssertEqual(recovered.persistence?.status, .saved)
        let restarted = try self.scanner().snapshot()
        XCTAssertEqual(restarted.totalTokens, 200)
        XCTAssertEqual(restarted.eventCount, 2)
        XCTAssertEqual(restarted.todayCost?.estimatedCostUSD, recovered.todayCost?.estimatedCostUSD)
    }

    func testPendingRetryRollsBackOnCancellationAndRejectedAccountCommit() throws {
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: false)
        let scanner = scanner()
        _ = try scanner.snapshot()
        try FileManager.default.removeItem(at: cacheURL)
        let cancellation = RefreshCancellation(deadline: Date().addingTimeInterval(60))
        cancellation.cancel()
        XCTAssertThrowsError(try scanner.snapshot(cancellation: cancellation))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        XCTAssertThrowsError(try scanner.snapshot(validateCommit: { false }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        XCTAssertEqual(try scanner.snapshot().persistence?.status, .saved)
        XCTAssertEqual(try self.scanner().snapshot().totalTokens, 100)
    }

    func testAnotherWriterKeepsCompatibleUnsavedAndSavedQuotaSamples() throws {
        let scanner = scanner()
        let start = now
        _ = try scanner.snapshot(weeklyWindow: window(20), accountContext: context("a"), quotaSampleAt: now)
        let saved = try obstructCache()
        now.addTimeInterval(60)
        try append(total: 200)
        XCTAssertEqual(try scanner.snapshot(weeklyWindow: window(21), accountContext: context("a"), quotaSampleAt: now).persistence?.status, .pending)
        try restoreCache(saved)
        now.addTimeInterval(60)
        try append(total: 300)
        _ = try self.scanner().snapshot(weeklyWindow: window(22), accountContext: context("a"), quotaSampleAt: now)
        let retry = try scanner.snapshot(weeklyWindow: window(22), accountContext: context("a"))
        XCTAssertEqual(retry.totalTokens, 300)
        XCTAssertEqual(retry.persistence?.status, .saved)
        let observation = try XCTUnwrap(diskCache().weeklyCostObservation)
        XCTAssertEqual(observation.startedAt, start)
        XCTAssertEqual(observation.baselineUsedPercent, 20)
        XCTAssertEqual(observation.history?.samples.map(\.usedPercent), [20, 21, 22])
        XCTAssertEqual(try self.scanner().snapshot(weeklyWindow: window(22), accountContext: context("a")).totalTokens, 300)
    }

    func testAnotherAccountHistoryIsNotMergedWithPendingSamples() throws {
        let scanner = scanner()
        _ = try scanner.snapshot(weeklyWindow: window(20), accountContext: context("a"), quotaSampleAt: now)
        let saved = try obstructCache()
        now.addTimeInterval(60)
        _ = try scanner.snapshot(weeklyWindow: window(21), accountContext: context("a"), quotaSampleAt: now)
        try restoreCache(saved)
        now.addTimeInterval(60)
        _ = try self.scanner().snapshot(weeklyWindow: window(50), accountContext: context("b"), quotaSampleAt: now)
        _ = try scanner.snapshot(weeklyWindow: window(50), accountContext: context("b"))
        let observation = try XCTUnwrap(diskCache().weeklyCostObservation)
        XCTAssertEqual(observation.accountScopeKey, context("b").scopeKey)
        XCTAssertEqual(observation.baselineUsedPercent, 50)
        XCTAssertEqual(observation.history?.samples.map(\.usedPercent), [50])
    }

    func testDeletedCacheIsRecreatedWithoutChangingLogsOrBaseline() throws {
        let scanner = scanner()
        _ = try scanner.snapshot(weeklyWindow: window(20), accountContext: context("a"), quotaSampleAt: now)
        let baseline = try XCTUnwrap(diskCache().weeklyCostObservation)
        try FileManager.default.removeItem(at: cacheURL)
        let recovered = try scanner.snapshot(weeklyWindow: window(20), accountContext: context("a"))
        XCTAssertEqual(recovered.persistence?.status, .saved)
        XCTAssertEqual(try diskCache().weeklyCostObservation?.history?.samples, baseline.history?.samples)
        XCTAssertEqual(try diskCache().weeklyCostObservation?.startedAt, baseline.startedAt)
    }

    func testDamagedDiskDoesNotDiscardTrustedInMemoryBaseline() throws {
        let scanner = scanner()
        _ = try scanner.snapshot(weeklyWindow: window(20), accountContext: context("a"), quotaSampleAt: now)
        let start = now
        now.addTimeInterval(60)
        try Data("broken".utf8).write(to: cacheURL, options: .atomic)
        let recovered = try scanner.snapshot(weeklyWindow: window(21), accountContext: context("a"), quotaSampleAt: now)
        XCTAssertEqual(recovered.persistence?.status, .saved)
        XCTAssertEqual(try diskCache().weeklyCostObservation?.startedAt, start)
        XCTAssertEqual(try diskCache().weeklyCostObservation?.history?.samples.map(\.usedPercent), [20, 21])
    }

    func testSuccessfulUnchangedScanDoesNotRewriteCacheAndLegacySnapshotStillDecodes() throws {
        let scanner = scanner()
        let initial = try scanner.snapshot()
        let stamp = UsageFileStamp.read(cacheURL)
        let second = try scanner.snapshot()
        XCTAssertEqual(second.persistence?.status, .saved)
        XCTAssertEqual(UsageFileStamp.read(cacheURL), stamp)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(initial)) as? [String: Any])
        legacy.removeValue(forKey: "persistence")
        let decoded = try JSONDecoder().decode(LocalUsageSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.persistence)
        XCTAssertEqual(decoded.totalTokens, 100)
    }

    func testDisabledDiskCacheAndEmptyScanHaveIndependentPersistenceStatus() throws {
        let memory = LocalUsageScanner(rootURLs: [root], calendar: calendar, now: { self.now })
        XCTAssertEqual(try memory.snapshot().persistence?.status, .disabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        try FileManager.default.removeItem(at: logURL)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: false)
        let empty = try scanner().snapshot()
        XCTAssertEqual(empty.diagnostics?.status, .empty)
        XCTAssertEqual(empty.persistence?.status, .pending)
        XCTAssertEqual(empty.totalTokens, 0)
        XCTAssertNil(empty.error)
    }

    func testReadFailureAndPendingWriteKeepSeparateErrorsUntilBothRecover() throws {
        let scanner = scanner()
        _ = try scanner.snapshot()
        let saved = try obstructCache()
        try append(total: 200)
        _ = try scanner.snapshot()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: logURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path) }
        let failed = try scanner.snapshot()
        XCTAssertEqual(failed.totalTokens, 200)
        XCTAssertEqual(failed.diagnostics?.status, .partial)
        XCTAssertNotNil(failed.error)
        XCTAssertNotNil(failed.persistence?.error)
        try restoreCache(saved)
        let savedButUnreadable = try scanner.snapshot()
        XCTAssertEqual(savedButUnreadable.persistence?.status, .saved)
        XCTAssertEqual(savedButUnreadable.diagnostics?.status, .partial)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        let recovered = try scanner.snapshot()
        XCTAssertEqual(recovered.diagnostics?.status, .complete)
        XCTAssertNil(recovered.error)
    }

    private func context(_ account: String) -> CodexAccountContext {
        CodexAccountContext(codexHome: root.path, authenticationSource: "fixture", accountKey: account,
                            accountLabel: nil, limitID: "codex")
    }

    private func window(_ used: Int) -> RateLimitWindow {
        RateLimitWindow(usedPercent: used, remainingPercent: 100 - used, windowDurationMins: 10080,
                        resetsAt: 1_789_286_400, resetsAtIso: nil)
    }

    private func diskCache() throws -> LocalUsageScanCache {
        try JSONDecoder().decode(LocalUsageCacheDocument.self, from: Data(contentsOf: cacheURL)).cache
    }

    private func obstructCache() throws -> URL {
        let saved = root.appendingPathComponent("saved-cache.json")
        try FileManager.default.moveItem(at: cacheURL, to: saved)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: false)
        return saved
    }

    private func restoreCache(_ saved: URL) throws {
        try FileManager.default.removeItem(at: cacheURL)
        try FileManager.default.moveItem(at: saved, to: cacheURL)
    }

    private func append(total: Int) throws {
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: event(total: total,
            timestamp: ISO8601DateFormatter().string(from: now))) + Data([0x0A]))
    }

    func testRetryRetainsWeeklyBaselineAndSamplesWithoutANewQuotaReading() throws {
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: false)
        let scanner = scanner()
        let context = CodexAccountContext(codexHome: root.path, authenticationSource: "fixture",
            accountKey: "a", accountLabel: nil, limitID: "codex")
        let window = RateLimitWindow(usedPercent: 20, remainingPercent: 80, windowDurationMins: 10080,
            resetsAt: Int(now.addingTimeInterval(86400).timeIntervalSince1970), resetsAtIso: nil)
        let first = try scanner.snapshot(weeklyWindow: window, accountContext: context, quotaSampleAt: now)
        XCTAssertEqual(try persistenceStatus(first), "pending")
        try FileManager.default.removeItem(at: cacheURL)
        let recovered = try scanner.snapshot(weeklyWindow: window, accountContext: context, quotaSampleAt: now)
        XCTAssertEqual(try persistenceStatus(recovered), "saved")
        let disk = try JSONDecoder().decode(LocalUsageCacheDocument.self, from: Data(contentsOf: cacheURL))
        XCTAssertEqual(disk.cache.weeklyCostObservation?.baselineUsedPercent, 20)
        XCTAssertEqual(disk.cache.weeklyCostObservation?.startedAt, now)
        XCTAssertEqual(disk.cache.weeklyCostObservation?.history?.samples, [WeeklyQuotaSample(timestamp: now, usedPercent: 20)])
    }

    private func scanner() -> LocalUsageScanner {
        LocalUsageScanner(rootURLs: [root], calendar: calendar, now: { self.now }, cacheFileURL: cacheURL)
    }

    private func persistenceStatus(_ snapshot: LocalUsageSnapshot) throws -> String? {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        return (json?["persistence"] as? [String: Any])?["status"] as? String
    }

    private func event(total: Int, timestamp: String) -> [String: Any] {
        ["type": "event_msg", "timestamp": timestamp, "payload": ["type": "token_count", "info": [
            "total_token_usage": ["input_tokens": total, "total_tokens": total], "last_token_usage": ["input_tokens": total]]]]
    }
}
