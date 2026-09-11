import Foundation
import XCTest
@testable import CodexRateLimitsCore

final class WeeklyQuotaSamplingTests: XCTestCase {
    private let start = ISO8601DateFormatter().date(from: "2026-09-11T00:00:00Z")!
    private var now = ISO8601DateFormatter().date(from: "2026-09-11T00:00:00Z")!
    private var root: URL!
    private var active: URL { root.appendingPathComponent("z-active") }
    private var other: URL { root.appendingPathComponent("a-other") }
    private var file: URL { active.appendingPathComponent("usage.jsonl") }
    private var cacheURL: URL { root.appendingPathComponent("cache.json") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WeeklyQuotaSampling-\(UUID())")
        for directory in [active, other] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try write([
            ["type": "session_meta", "payload": ["id": "weekly-session"]],
            ["type": "turn_context", "payload": ["model": "gpt-5.6-sol", "service_tier": "standard"]]
        ], to: file)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func scanner(copies: Bool = false) -> CodexBackend.LocalUsageScanner {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return CodexBackend.LocalUsageScanner(rootURLs: copies ? [other, active] : [active], calendar: calendar,
            now: { self.now }, cacheFileURL: cacheURL, weeklyRootURLs: [active])
    }
    private func at(_ minute: Int) -> Date { start.addingTimeInterval(Double(minute) * 60) }
    private func window(_ minute: Int) -> RateLimitWindow {
        let used = 10 + minute / 6
        return RateLimitWindow(usedPercent: used, remainingPercent: 100 - used, windowDurationMins: 10080,
                               resetsAt: Int(start.addingTimeInterval(5 * 86400).timeIntervalSince1970), resetsAtIso: nil)
    }
    private func write(_ events: [[String: Any]], to file: URL, append: Bool = false) throws {
        let data = try events.reduce(into: Data()) { data, event in
            data.append(try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])); data.append(0x0A)
        }
        if append {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        } else { try data.write(to: file, options: .atomic) }
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    }
    private func token(_ total: Int, at timestamp: Date) -> [String: Any] {
        ["timestamp": ISO8601DateFormatter().string(from: timestamp), "type": "event_msg",
         "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": total, "total_tokens": total],
                                                      "last_token_usage": ["input_tokens": 1000]]]]
    }
    private func train(_ scanner: CodexBackend.LocalUsageScanner, copies: Bool = false,
                       context: CodexAccountContext? = nil) throws -> LocalUsageSnapshot {
        _ = try scanner.snapshot(weeklyWindow: window(0), accountContext: context, quotaSampleAt: now)
        var result: LocalUsageSnapshot!
        for minute in stride(from: 5, through: 95, by: 5) {
            now = at(minute)
            try write((minute - 4...minute).map { token($0 * 1000, at: at($0).addingTimeInterval(-30)) }, to: file, append: true)
            if copies { try Data(contentsOf: file).write(to: other.appendingPathComponent("renamed.jsonl"), options: .atomic) }
            result = try scanner.snapshot(weeklyWindow: window(minute), accountContext: context, quotaSampleAt: now)
        }
        return result
    }

    func testFreshSamplesPersistAndLaterUsageDoesNotPairWithAnOldQuotaReading() throws {
        let scanner = scanner()
        let trained = try train(scanner)
        XCTAssertEqual(trained.weeklyQuotaCost?.valuation?.status, .ready)
        XCTAssertEqual(trained.weeklyQuotaCost?.valuation?.effectiveIntervalCount, 3)
        XCTAssertEqual(try XCTUnwrap(trained.weeklyQuotaCost?.estimatedQuotaUSD), 2.4, accuracy: 0.000001)
        now = at(96)
        try write([token(200_000, at: at(96).addingTimeInterval(-30))], to: file, append: true)
        let repeated = try self.scanner().snapshot(weeklyWindow: window(95), quotaSampleAt: at(95))
        XCTAssertEqual(repeated.totalTokens, 200_000)
        XCTAssertEqual(repeated.weeklyQuotaCost?.estimatedQuotaUSD, trained.weeklyQuotaCost?.estimatedQuotaUSD)
        XCTAssertEqual(repeated.weeklyQuotaCost?.valuation?.sampleCount, trained.weeklyQuotaCost?.valuation?.sampleCount)
        now = at(101)
        let stale = try scanner.snapshot(weeklyWindow: window(95), quotaSampleAt: at(95))
        XCTAssertEqual(stale.weeklyQuotaCost?.inferencePauseReason, "staleQuota")
        XCTAssertNil(stale.weeklyQuotaCost?.estimatedQuotaUSD)
        XCTAssertEqual(stale.weeklyQuotaCost?.observationStartIso, trained.weeklyQuotaCost?.observationStartIso)
    }

    func testRepricingAndRebuildRecalculateTimedCostsAndPreserveSamples() throws {
        let scanner = scanner()
        let before = try train(scanner)
        let text = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "gpt-5.6-sol", with: "gpt-5.6-terra")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let repriced = try scanner.snapshot(weeklyWindow: window(95), quotaSampleAt: now)
        XCTAssertEqual(try XCTUnwrap(repriced.weeklyQuotaCost?.estimatedQuotaUSD), 1.2, accuracy: 0.000001)
        let rebuilt = try self.scanner().snapshot(weeklyWindow: window(95), rebuild: true, quotaSampleAt: now)
        XCTAssertEqual(rebuilt.weeklyQuotaCost?.estimatedQuotaUSD, repriced.weeklyQuotaCost?.estimatedQuotaUSD)
        XCTAssertEqual(rebuilt.weeklyQuotaCost?.valuation?.sampleCount, before.weeklyQuotaCost?.valuation?.sampleCount)
        XCTAssertEqual(rebuilt.weeklyQuotaCost?.observationStartIso, before.weeklyQuotaCost?.observationStartIso)
    }

    func testAccountAndQuotaResetStartNewEvidenceAndIgnoreLateOldWindows() throws {
        let scanner = scanner()
        func context(_ key: String) -> CodexAccountContext {
            CodexAccountContext(codexHome: root.path, authenticationSource: "fixture", accountKey: key,
                                accountLabel: nil, limitID: "codex")
        }
        let before = try train(scanner, context: context("a"))
        let switched = try scanner.snapshot(weeklyWindow: window(95), accountContext: context("b"), quotaSampleAt: now)
        XCTAssertEqual(switched.totalTokens, before.totalTokens)
        XCTAssertEqual(switched.weeklyQuotaCost?.valuation?.effectiveIntervalCount, 0)
        XCTAssertNil(switched.weeklyQuotaCost?.estimatedQuotaUSD)
        now = at(100)
        let reset = RateLimitWindow(usedPercent: 0, remainingPercent: 100, windowDurationMins: 10080,
                                    resetsAt: Int(now.addingTimeInterval(7 * 86400).timeIntervalSince1970), resetsAtIso: nil)
        let fresh = try scanner.snapshot(weeklyWindow: reset, accountContext: context("b"), quotaSampleAt: now)
        XCTAssertEqual(fresh.weeklyQuotaCost?.baselineUsedPercent, 0)
        _ = try scanner.snapshot(weeklyWindow: window(95), accountContext: context("b"), quotaSampleAt: at(95))
        let retained = try scanner.snapshot(weeklyWindow: reset, accountContext: context("b"), quotaSampleAt: now)
        XCTAssertEqual(retained.weeklyQuotaCost?.observationStartIso, fresh.weeklyQuotaCost?.observationStartIso)
        XCTAssertEqual(retained.weeklyQuotaCost?.baselineUsedPercent, 0)
    }

    func testCopiedLogsRetainActiveWeeklyTimelineAndAnUnrelatedFailureDoesNotBlockIt() throws {
        let scanner = scanner(copies: true)
        let trained = try train(scanner, copies: true)
        XCTAssertEqual(trained.totalTokens, 95_000)
        XCTAssertEqual(try XCTUnwrap(trained.weeklyQuotaCost?.estimatedQuotaUSD), 2.4, accuracy: 0.000001)
        let bad = other.appendingPathComponent("unrelated.jsonl")
        try Data("not json\n".utf8).write(to: bad)
        let partial = try scanner.snapshot(weeklyWindow: window(95), quotaSampleAt: now)
        XCTAssertEqual(partial.diagnostics?.status, .partial)
        XCTAssertEqual(partial.weeklyQuotaCost?.valuation?.status, .ready)
        XCTAssertEqual(partial.weeklyQuotaCost?.estimatedQuotaUSD, trained.weeklyQuotaCost?.estimatedQuotaUSD)
    }

    func testOneUnknownTokenPausesTheAffectedIntervalDespiteNearFullPriceCoverage() throws {
        let scanner = scanner()
        _ = try train(scanner)
        try write([["type": "turn_context", "payload": ["model": "unknown-model", "service_tier": "standard"]],
                   token(95_001, at: at(95).addingTimeInterval(-10))], to: file, append: true)
        let partial = try scanner.snapshot(weeklyWindow: window(95), quotaSampleAt: now)
        XCTAssertGreaterThan(partial.weeklyQuotaCost?.coveragePercent ?? 0, 99)
        XCTAssertEqual(partial.weeklyQuotaCost?.inferencePauseReason, "unpricedUsage")
        XCTAssertNil(partial.weeklyQuotaCost?.estimatedQuotaUSD)
    }

    func testLegacyAggregateMigrationPreservesBaselineAndStartsTimedEvidenceNow() throws {
        let trained = try train(scanner())
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as! [String: Any]
        var cache = document["cache"] as! [String: Any]
        var observation = cache["weeklyCostObservation"] as! [String: Any]
        observation["timelineStartedAt"] = nil
        observation["history"] = nil
        cache["weeklyCostObservation"] = observation
        var files = cache["files"] as! [String: [String: Any]]
        for path in files.keys { files[path]?["weeklyTimeline"] = nil }
        cache["files"] = files
        document["cache"] = cache
        try JSONSerialization.data(withJSONObject: document).write(to: cacheURL, options: .atomic)
        let migrated = try scanner().snapshot(weeklyWindow: window(95), quotaSampleAt: now)
        XCTAssertEqual(migrated.totalTokens, trained.totalTokens)
        XCTAssertEqual(migrated.weeklyQuotaCost?.observedCostUSD, trained.weeklyQuotaCost?.observedCostUSD)
        XCTAssertEqual(migrated.weeklyQuotaCost?.observationStartIso, trained.weeklyQuotaCost?.observationStartIso)
        XCTAssertEqual(migrated.weeklyQuotaCost?.valuation?.effectiveIntervalCount, 0)
        XCTAssertNil(migrated.weeklyQuotaCost?.estimatedQuotaUSD)
    }
}
