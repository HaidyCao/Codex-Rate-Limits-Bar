import Foundation
import XCTest
@testable import CodexRateLimitsCore

final class CumulativeUsageCorrectionTests: XCTestCase {
    private var root: URL!
    private var now = ISO8601DateFormatter().date(from: "2026-09-11T10:00:00Z")!
    private var sessions: URL { root.appendingPathComponent("sessions") }
    private var file: URL { sessions.appendingPathComponent("usage.jsonl") }
    private var cache: URL { root.appendingPathComponent("cache.json") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("UsageCorrection-\(UUID())")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testComponentCorrectionKeepsOneCoherentBaselineAndNextDeltaIsPriced() throws {
        let first = usage(input: 1_000, cached: 800, output: 100, reasoning: 80)
        let corrected = usage(input: 1_200, cached: 900, output: 50, reasoning: 30)
        let next = usage(input: 1_300, cached: 950, output: 60, reasoning: 35)
        let ambiguous = try XCTUnwrap(LocalUsageLog.positiveDelta(first, corrected, sameSession: true))
        XCTAssertEqual(ambiguous.totalTokens, 150)
        XCTAssertFalse(ambiguous.hasCompleteBreakdown)
        let baseline = LocalUsageLog.maxTokenUsage(first, corrected)
        XCTAssertEqual(baseline, corrected)
        let delta = try XCTUnwrap(LocalUsageLog.positiveDelta(baseline, next, sameSession: true))
        XCTAssertEqual(delta, usage(input: 100, cached: 50, output: 10, reasoning: 5))
        XCTAssertEqual(try XCTUnwrap(TokenCostEstimator.estimateUSD(usage: delta, model: "gpt-5.6-sol")), 0.00042, accuracy: 1e-12)
    }

    func testRegressedTotalCannotPoisonAcceptedComponents() throws {
        let accepted = usage(input: 1_000, cached: 600, output: 500, reasoning: 200)
        let regressed = usage(input: 1_300, cached: 900, output: 100, reasoning: 50)
        XCTAssertNil(LocalUsageLog.positiveDelta(accepted, regressed, sameSession: true))
        let baseline = LocalUsageLog.maxTokenUsage(accepted, regressed)
        XCTAssertEqual(baseline, accepted)
        let next = usage(input: 1_100, cached: 650, output: 550, reasoning: 220)
        let delta = try XCTUnwrap(LocalUsageLog.positiveDelta(baseline, next, sameSession: true))
        XCTAssertEqual(delta, usage(input: 100, cached: 50, output: 50, reasoning: 20))
        XCTAssertTrue(delta.hasCompleteBreakdown)
    }

    func testSameTotalCorrectionCanRepairTheBaselineWithoutCountingTokensAgain() throws {
        let first = usage(input: 1_000, cached: 800, output: 100)
        let correction = usage(input: 1_050, cached: 850, output: 50)
        XCTAssertEqual(LocalUsageLog.maxTokenUsage(first, correction), correction)
        let next = usage(input: 1_150, cached: 900, output: 60)
        let delta = try XCTUnwrap(LocalUsageLog.positiveDelta(LocalUsageLog.maxTokenUsage(first, correction), next, sameSession: true))
        XCTAssertEqual(delta.totalTokens, 110)
        XCTAssertTrue(delta.hasCompleteBreakdown)
    }

    func testCachedAndReasoningCorrectionsAreNotSilentlyPricedAsZero() throws {
        let first = usage(input: 1_000, cached: 800, output: 100, reasoning: 80)
        for corrected in [usage(input: 1_200, cached: 700, output: 150, reasoning: 100),
                          usage(input: 1_200, cached: 900, output: 150, reasoning: 50)] {
            let delta = try XCTUnwrap(LocalUsageLog.positiveDelta(first, corrected, sameSession: true))
            XCTAssertEqual(delta.totalTokens, 250)
            XCTAssertNil(TokenCostEstimator.estimateUSD(usage: delta, model: "gpt-5.6-sol"))
            XCTAssertNil(CodexCreditEstimator.estimate(usage: delta, model: "gpt-5.6-sol", requestInputTokens: 200, serviceTier: "standard"))
        }
    }

    func testCorrectedUsageStaysPricedAcrossAppendRestartRebuildAndCopies() throws {
        for copies in [false, true] {
            if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
            for path in try FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil) {
                try FileManager.default.removeItem(at: path)
            }
            let scanner = makeScanner()
            let baseline = try read(scanner)
            try append(usage(input: 1_000, cached: 800, output: 100, reasoning: 80))
            _ = try read(scanner)
            try append(usage(input: 1_200, cached: 900, output: 50, reasoning: 30))
            let ambiguous = try read(scanner)
            XCTAssertEqual(ambiguous.todayCost?.unpricedTokens, 150)
            try append(usage(input: 1_300, cached: 950, output: 60, reasoning: 35))
            if copies { try FileManager.default.copyItem(at: file, to: sessions.appendingPathComponent("copy.jsonl")) }
            let recovered = try read(makeScanner())
            XCTAssertEqual(recovered.totalTokens, 1_360)
            XCTAssertEqual(recovered.todayCost?.unpricedTokens, 150)
            XCTAssertEqual(try XCTUnwrap(recovered.todayCost?.estimatedCostUSD), 0.00354, accuracy: 1e-12)
            XCTAssertEqual(try XCTUnwrap(recovered.todayCredits?.estimatedCredits), 0.0885, accuracy: 1e-12)
            try append(usage(input: 1_400, cached: 1_000, output: 70, reasoning: 40))
            let incremental = try read(scanner)
            let rebuilt = try read(makeScanner(), rebuild: true)
            XCTAssertEqual(incremental.totalTokens, 1_470)
            XCTAssertEqual(incremental.todayCost?.unpricedTokens, 150)
            XCTAssertEqual(incremental.weeklyQuotaCost?.unpricedTokens, 150)
            XCTAssertEqual(try XCTUnwrap(incremental.todayCost?.estimatedCostUSD), 0.00396, accuracy: 1e-12)
            XCTAssertEqual(try XCTUnwrap(incremental.todayCredits?.estimatedCredits), 0.099, accuracy: 1e-12)
            XCTAssertEqual(incremental.weeklyQuotaCost?.baselineUsedPercent, baseline.weeklyQuotaCost?.baselineUsedPercent)
            XCTAssertEqual(incremental.weeklyQuotaCost?.observationStartIso, baseline.weeklyQuotaCost?.observationStartIso)
            XCTAssertEqual(incremental.todayCost?.estimatedCostUSD, rebuilt.todayCost?.estimatedCostUSD)
            XCTAssertEqual(incremental.todayCredits?.estimatedCredits, rebuilt.todayCredits?.estimatedCredits)
            XCTAssertEqual(incremental.weeklyQuotaCost?.observedCostUSD, rebuilt.weeklyQuotaCost?.observedCostUSD)
            XCTAssertEqual(incremental.totalTokens, rebuilt.totalTokens)
        }
    }

    func testTotalRegressionKeepsPriceableUsageAndDoesNotDoubleCount() throws {
        let scanner = makeScanner()
        _ = try read(scanner)
        try append(usage(input: 1_000, cached: 600, output: 500, reasoning: 200))
        _ = try read(scanner)
        try append(usage(input: 1_300, cached: 900, output: 100, reasoning: 50))
        XCTAssertEqual(try read(scanner).totalTokens, 1_500)
        try append(usage(input: 1_100, cached: 650, output: 550, reasoning: 220))
        let value = try read(makeScanner())
        XCTAssertEqual(value.totalTokens, 1_650)
        XCTAssertEqual(value.regressionEventCount, 1)
        XCTAssertEqual(value.todayCost?.unpricedTokens, 0)
        XCTAssertEqual(try XCTUnwrap(value.todayCost?.estimatedCostUSD), 0.01306, accuracy: 1e-12)
    }

    func testOldCacheReplaysInvalidBaselineAndPreservesOfficialHistory() throws {
        let scanner = makeScanner()
        _ = try read(scanner)
        try append(usage(input: 1_000, cached: 800, output: 100))
        _ = try read(scanner)
        try append(usage(input: 1_200, cached: 900, output: 50))
        _ = try read(scanner)
        try append(usage(input: 1_300, cached: 950, output: 60))
        let expected = try read(scanner)
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! [String: Any]
        var cached = document["cache"] as! [String: Any]
        let observation = cached["weeklyCostObservation"] as! NSDictionary
        var files = cached["files"] as! [String: [String: Any]]
        for path in files.keys {
            var state = files[path]!
            var diagnostics = state["diagnostics"] as! [String: Any]
            diagnostics["version"] = 2
            state["diagnostics"] = diagnostics
            state["previousTotalUsage"] = ["inputTokens": 1_300, "cachedInputTokens": 950, "cacheWriteInputTokens": 0,
                                            "outputTokens": 100, "reasoningOutputTokens": 0, "totalTokens": 1_360]
            state["dailyCost"] = ["buckets": [:]]
            state["weeklyCost"] = ["buckets": [:]]
            state["weeklyTimeline"] = [String: Any]()
            files[path] = state
        }
        cached["files"] = files; document["cache"] = cached
        try JSONSerialization.data(withJSONObject: document).write(to: cache, options: .atomic)
        let migrated = try read(makeScanner())
        XCTAssertEqual(migrated.todayCost?.estimatedCostUSD, expected.todayCost?.estimatedCostUSD)
        XCTAssertEqual(migrated.weeklyQuotaCost?.observedCostUSD, expected.weeklyQuotaCost?.observedCostUSD)
        XCTAssertEqual(migrated.todayCost?.unpricedTokens, 150)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! [String: Any]
        let restored = saved["cache"] as! [String: Any]
        XCTAssertEqual(restored["weeklyCostObservation"] as! NSDictionary, observation)
        XCTAssertEqual(saved["version"] as? Int, 4)
        try append(usage(input: 1_400, cached: 1_000, output: 70))
        XCTAssertEqual(try read(makeScanner()).todayCost?.unpricedTokens, 150)
    }

    private func makeScanner() -> LocalUsageScanner {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return LocalUsageScanner(rootURLs: [sessions], calendar: calendar, now: { self.now }, cacheFileURL: cache)
    }

    private func read(_ scanner: LocalUsageScanner, rebuild: Bool = false) throws -> LocalUsageSnapshot {
        let window = RateLimitWindow(usedPercent: 20, remainingPercent: 80, windowDurationMins: 10080,
                                     resetsAt: nil, resetsAtIso: "2026-09-17T16:00:00Z")
        return try scanner.snapshot(weeklyWindow: window, rebuild: rebuild, quotaSampleAt: now)
    }

    private func append(_ usage: TokenUsage) throws {
        now.addTimeInterval(60)
        var events: [[String: Any]] = []
        if !FileManager.default.fileExists(atPath: file.path) {
            events = [["type": "session_meta", "payload": ["id": "corrected-session"]],
                      ["type": "turn_context", "payload": ["model": "gpt-5.6-sol", "service_tier": "standard"]]]
        }
        events.append(["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: now),
                       "payload": ["type": "token_count", "info": [
                        "total_token_usage": ["input_tokens": usage.inputTokens, "cached_input_tokens": usage.cachedInputTokens,
                                              "output_tokens": usage.outputTokens, "reasoning_output_tokens": usage.reasoningOutputTokens,
                                              "total_tokens": usage.totalTokens],
                        "last_token_usage": ["input_tokens": 100]]]])
        var data = Data()
        for event in events { data.append(try JSONSerialization.data(withJSONObject: event)); data.append(10) }
        if FileManager.default.fileExists(atPath: file.path) {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        } else { try data.write(to: file) }
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    }

    private func usage(input: Int64, cached: Int64, output: Int64, reasoning: Int64 = 0) -> TokenUsage {
        TokenUsage(inputTokens: input, cachedInputTokens: cached, outputTokens: output,
                   reasoningOutputTokens: reasoning, totalTokens: input + output)
    }
}
