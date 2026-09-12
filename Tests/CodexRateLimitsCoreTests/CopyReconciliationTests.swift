import Foundation
import XCTest
@testable import CodexRateLimitsCore

final class CopyReconciliationTests: XCTestCase {
    private var root: URL!
    private var now = ISO8601DateFormatter().date(from: "2026-09-11T00:00:00Z")!
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var window: RateLimitWindow {
        RateLimitWindow(usedPercent: 10, remainingPercent: 90, windowDurationMins: 10080,
                        resetsAt: 1_789_632_000, resetsAtIso: nil)
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CopyReconciliation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func scanner(weeklyRoots: [URL]? = nil) -> LocalUsageScanner {
        LocalUsageScanner(rootURLs: [root], calendar: calendar, now: { self.now },
            cacheFileURL: root.appendingPathComponent("cache.json"), weeklyRootURLs: weeklyRoots)
    }
    private func token(_ total: Int, _ second: Int, model: String = "gpt-5.6-sol") -> [String: Any] {
        let date = ISO8601DateFormatter().date(from: "2026-09-11T00:00:00Z")!.addingTimeInterval(Double(second))
        return ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: date), "payload": [
            "type": "token_count", "info": ["model": model, "service_tier": "standard",
                "total_token_usage": ["input_tokens": total, "total_tokens": total],
                "last_token_usage": ["input_tokens": 100]]]]
    }
    private func write(_ events: [[String: Any]], to name: String, prefix: String = "", id: String = "shared-session") throws {
        let file = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(prefix.utf8)
        for event in [["type": "session_meta", "payload": ["id": id]]] + events {
            data.append(try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])); data.append(10)
        }
        try data.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    }
    private func assertUsage(_ value: LocalUsageSnapshot, total: Int64, dollars: Double? = nil, credits: Double? = nil,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(value.totalTokens, total, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(value.todayCost?.estimatedCostUSD), dollars ?? Double(total) * 0.000004,
                       accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(value.todayCredits?.estimatedCredits), credits ?? Double(total) * 0.0001,
                       accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(value.diagnostics?.status, .complete, file: file, line: line)
    }

    func testComplementaryPrefixesCountOnceAcrossRestartRebuildAndFileOrder() throws {
        let histories = [[token(100, 1), token(300, 3)], [token(200, 2), token(300, 3)]]
        now.addTimeInterval(60)
        for order in [histories, histories.reversed().map { $0 }] {
            try write(order[0], to: "a.jsonl")
            try write(order[1], to: "b.jsonl")
            let reader = scanner()
            for value in [try reader.snapshot(), try reader.snapshot(), try scanner().snapshot(), try reader.snapshot(rebuild: true)] {
                try assertUsage(value, total: 300)
            }
        }
    }

    func testAConvergenceRepairsPreviouslySeparateTailsAndLaterTailsRemainDistinct() throws {
        now.addTimeInterval(60)
        let a = [token(100, 1), token(200, 2)]
        let b = [token(100, 1), token(250, 3)]
        try write(a, to: "a.jsonl"); try write(b, to: "b.jsonl")
        let reader = scanner()
        try assertUsage(reader.snapshot(), total: 350)
        try write(a + [token(300, 4)], to: "a.jsonl")
        try write(b + [token(300, 4)], to: "b.jsonl")
        try assertUsage(reader.snapshot(), total: 300)
        try write(a + [token(300, 4), token(350, 5)], to: "a.jsonl")
        try write(b + [token(300, 4), token(400, 6)], to: "b.jsonl")
        for value in [try reader.snapshot(), try scanner().snapshot(), try reader.snapshot(rebuild: true)] {
            try assertUsage(value, total: 450)
        }
    }

    func testPartiallySharedConvergencesDoNotCollapseDifferentBranches() throws {
        now.addTimeInterval(60)
        let histories = [[token(100, 1), token(200, 2), token(400, 4)],
                         [token(100, 1), token(300, 3), token(400, 4)],
                         [token(100, 1), token(200, 2), token(500, 6)],
                         [token(100, 1), token(450, 5), token(500, 6)]]
        for (index, events) in histories.enumerated() { try write(events, to: "\(index).jsonl") }
        try assertUsage(scanner().snapshot(), total: 700)
        try assertUsage(scanner().snapshot(rebuild: true), total: 700)
    }

    func testOutsideCopiesDoNotRemoveActiveWeeklyUsage() throws {
        let active = root.appendingPathComponent("active")
        try write([], to: "active/a.jsonl"); try write([], to: "outside/b.jsonl")
        let reader = scanner(weeklyRoots: [active])
        let baseline = try reader.snapshot(weeklyWindow: window, quotaSampleAt: now)
        now.addTimeInterval(60)
        try write([token(100, 1), token(300, 3)], to: "active/a.jsonl")
        try write([token(200, 2), token(300, 3)], to: "outside/b.jsonl")
        for value in [try reader.snapshot(weeklyWindow: window, quotaSampleAt: now),
                      try scanner(weeklyRoots: [active]).snapshot(weeklyWindow: window, quotaSampleAt: now),
                      try reader.snapshot(weeklyWindow: window, rebuild: true, quotaSampleAt: now)] {
            try assertUsage(value, total: 300)
            XCTAssertEqual(try XCTUnwrap(value.weeklyQuotaCost?.observedCostUSD), 0.0012, accuracy: 1e-12)
            XCTAssertEqual(value.weeklyQuotaCost?.observationStartIso, baseline.weeklyQuotaCost?.observationStartIso)
        }
    }

    func testReconciliationUsesSamplesBeforeMidnightToComputeToday() throws {
        now.addTimeInterval(60)
        try write([token(100, -1), token(300, 3)], to: "a.jsonl")
        try write([token(200, 2), token(300, 3)], to: "b.jsonl")
        try assertUsage(scanner().snapshot(), total: 200)
        try assertUsage(scanner().snapshot(rebuild: true), total: 200)
    }

    func testLeadingBlankLinesIdentifyCopiesOnTheFirstScan() throws {
        now.addTimeInterval(60)
        try write([token(100, 1)], to: "a.jsonl", prefix: "\n\r\n \t\r\n")
        try write([token(100, 1)], to: "b.jsonl")
        let reader = scanner()
        for value in [try reader.snapshot(), try reader.snapshot(), try scanner().snapshot(), try reader.snapshot(rebuild: true)] {
            try assertUsage(value, total: 100)
            XCTAssertEqual(value.topFiles?.first?.sourceFiles?.count, 2)
        }
    }

    func testRefinedIntervalsKeepTheirOwnModelAndTokenComponents() throws {
        now.addTimeInterval(60)
        try write([token(100, 1), token(300, 3)], to: "a.jsonl")
        try write([token(200, 2, model: "gpt-5.6-luna"), token(300, 3)], to: "b.jsonl")
        try assertUsage(scanner().snapshot(), total: 300, dollars: 0.00082, credits: 0.0205)
        func mixed(_ total: Int, _ input: Int, _ cached: Int, _ output: Int, _ second: Int) -> [String: Any] {
            var value = token(total, second)
            value["payload"] = ["type": "token_count", "info": ["model": "gpt-5.6-sol", "service_tier": "standard",
                "total_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output, "total_tokens": total],
                "last_token_usage": ["input_tokens": 100]]]
            return value
        }
        let final = mixed(300, 230, 100, 70, 3)
        try write([mixed(100, 80, 20, 20, 1), final], to: "a.jsonl")
        try write([mixed(200, 130, 50, 70, 2), final], to: "b.jsonl")
        for value in [try scanner().snapshot(), try scanner().snapshot(rebuild: true)] {
            try assertUsage(value, total: 300, dollars: 0.00196, credits: 0.049)
            XCTAssertEqual(value.inputTokens, 230)
            XCTAssertEqual(value.cachedInputTokens, 100)
            XCTAssertEqual(value.outputTokens, 70)
        }
    }

    func testForkImportRemainsExcludedWhenCopiedChildHistoriesConverge() throws {
        now.addTimeInterval(60)
        let inherited: [[String: Any]] = [["type": "session_meta", "payload": ["id": "parent"]], token(100, 0),
                                         ["type": "session_meta", "payload": ["id": "shared-session"]]]
        try write(inherited + [token(200, 1), token(400, 3)], to: "a.jsonl")
        try write(inherited + [token(300, 2), token(400, 3)], to: "b.jsonl")
        try assertUsage(scanner().snapshot(), total: 300)
        try assertUsage(scanner().snapshot(rebuild: true), total: 300)
    }

    func testOldCopyCacheReplaysWithoutResettingWeeklyHistoryOrReplayingAnUnrelatedFile() throws {
        try write([], to: "a.jsonl"); try write([], to: "b.jsonl")
        let reader = scanner()
        let baseline = try reader.snapshot(weeklyWindow: window, quotaSampleAt: now)
        now.addTimeInterval(60)
        try write([token(100, 1), token(300, 3)], to: "a.jsonl")
        try write([token(200, 2), token(300, 3)], to: "b.jsonl")
        try write([token(50, 1)], to: "unrelated.jsonl", id: "another-session")
        _ = try reader.snapshot(weeklyWindow: window, quotaSampleAt: now)
        let file = root.appendingPathComponent("cache.json")
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var cache = document["cache"] as! [String: Any]
        let observation = cache["weeklyCostObservation"] as! NSDictionary
        var files = cache["files"] as! [String: [String: Any]]
        for path in files.keys {
            files[path]?["copyAlgorithmVersion"] = nil
            var diagnostics = files[path]?["diagnostics"] as! [String: Any]
            diagnostics.removeValue(forKey: "blankLinesChecked")
            files[path]?["diagnostics"] = diagnostics
            if path.hasSuffix("a.jsonl") {
                var totals = files[path]?["totals"] as! [String: Any]
                totals["totalTokens"] = (totals["totalTokens"] as! Int) + 100
                files[path]?["totals"] = totals
            }
        }
        cache["files"] = files; document["cache"] = cache
        try JSONSerialization.data(withJSONObject: document).write(to: file, options: .atomic)
        let migrated = try scanner().snapshot(weeklyWindow: window, quotaSampleAt: now)
        try assertUsage(migrated, total: 350)
        XCTAssertEqual(migrated.weeklyQuotaCost?.observationStartIso, baseline.weeklyQuotaCost?.observationStartIso)
        let updated = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let updatedCache = updated["cache"] as! [String: Any]
        XCTAssertEqual(updatedCache["weeklyCostObservation"] as! NSDictionary, observation)
        let updatedFiles = updatedCache["files"] as! [String: [String: Any]]
        for (path, state) in updatedFiles {
            if path.hasSuffix("unrelated.jsonl") {
                XCTAssertNil((state["diagnostics"] as? [String: Any])?["blankLinesChecked"], "An unchanged, valid single file should reuse its old cache")
            } else { XCTAssertEqual(state["copyAlgorithmVersion"] as? Int, UsageCopyLedger.currentVersion) }
        }
    }

    func testConflictingChronologyRemainsVisibleAcrossRestartAndRecovers() throws {
        now.addTimeInterval(60)
        try write([token(100, 2), token(300, 3)], to: "a.jsonl")
        try write([token(200, 1), token(300, 3)], to: "b.jsonl")
        let reader = scanner()
        for value in [try reader.snapshot(), try reader.snapshot(), try scanner().snapshot()] {
            XCTAssertEqual(value.diagnostics?.status, .partial)
            XCTAssertTrue(value.diagnostics?.issues.contains { $0.kind == .copyReplayIncomplete } == true)
        }
        try write([token(100, 1), token(300, 3)], to: "a.jsonl")
        try write([token(200, 2), token(300, 3)], to: "b.jsonl")
        try assertUsage(reader.snapshot(), total: 300)
    }

    func testBlankHeaderCanCrossChunksAndStillHonorsCancellation() throws {
        try write([token(100, 1)], to: "a.jsonl", prefix: String(repeating: " \t\r\n", count: 2048))
        let file = root.appendingPathComponent("a.jsonl")
        XCTAssertEqual(try UsageFileIdentity.sessionID(at: file), "shared-session")
        let cancellation = RefreshCancellation(deadline: Date().addingTimeInterval(10))
        cancellation.cancel()
        XCTAssertThrowsError(try RefreshWork.$cancellation.withValue(cancellation) { try UsageFileIdentity.sessionID(at: file) })
    }

    func testManyComplementarySubsequencesShareTheFinalCumulativeTotal() throws {
        now.addTimeInterval(600)
        for trial in 0..<4 {
            for copy in 0..<8 {
                let samples = (1...80).filter { $0 == 80 || ($0 * 17 + copy * 5 + trial * 3) % 7 < 2 }
                try write(samples.map { token($0 * 10, $0) }, to: "\(copy).jsonl")
            }
            let reader = scanner()
            try assertUsage(reader.snapshot(), total: 800)
            try assertUsage(reader.snapshot(), total: 800)
            try assertUsage(scanner().snapshot(rebuild: true), total: 800)
        }
    }

    func testOutsideHistoryConflictDoesNotInvalidateCleanWeeklySources() throws {
        let active = root.appendingPathComponent("active")
        try write([], to: "active/a.jsonl"); try write([], to: "outside/b.jsonl")
        let reader = scanner(weeklyRoots: [active])
        _ = try reader.snapshot(weeklyWindow: window, quotaSampleAt: now)
        now.addTimeInterval(60)
        try write([token(100, 2), token(300, 3)], to: "active/a.jsonl")
        try write([token(200, 1), token(300, 3)], to: "outside/b.jsonl")
        for value in [try reader.snapshot(weeklyWindow: window, quotaSampleAt: now),
                      try scanner(weeklyRoots: [active]).snapshot(weeklyWindow: window, quotaSampleAt: now)] {
            XCTAssertEqual(value.diagnostics?.status, .partial)
            XCTAssertEqual(value.weeklyQuotaCost?.scanStatus, .complete)
            XCTAssertEqual(try XCTUnwrap(value.weeklyQuotaCost?.observedCostUSD), 0.0012, accuracy: 1e-12)
        }
    }

    func testLegacyWhitespaceParseErrorsAreRecheckedOnce() throws {
        now.addTimeInterval(60)
        try write([token(100, 1)], to: "a.jsonl", prefix: " \t\n")
        _ = try scanner().snapshot()
        let file = root.appendingPathComponent("cache.json")
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var cache = document["cache"] as! [String: Any]
        var files = cache["files"] as! [String: [String: Any]]
        let path = files.keys.first!
        var diagnostics = files[path]?["diagnostics"] as! [String: Any]
        diagnostics.removeValue(forKey: "blankLinesChecked")
        files[path]?["diagnostics"] = diagnostics
        files[path]?["parseErrorCount"] = 1
        cache["files"] = files; document["cache"] = cache
        try JSONSerialization.data(withJSONObject: document).write(to: file, options: .atomic)
        let reader = scanner()
        try assertUsage(reader.snapshot(), total: 100)
        try assertUsage(reader.snapshot(), total: 100)
    }

    func testTimestampOffsetsAndFractionalSecondsIdentifyTheSameCopiedEvent() throws {
        now.addTimeInterval(60)
        var a = token(100, 1), b = token(100, 1)
        a["timestamp"] = "2026-09-11T00:00:01.125Z"
        b["timestamp"] = "2026-09-11T08:00:01.125+08:00"
        try write([a, token(200, 2)], to: "a.jsonl")
        try write([b, token(200, 2)], to: "b.jsonl")
        try assertUsage(scanner().snapshot(), total: 200)
        try assertUsage(scanner().snapshot(rebuild: true), total: 200)
    }

    func testNewWeeklyObservationDoesNotInheritAnOldCopyConflict() throws {
        try write([], to: "a.jsonl"); try write([], to: "b.jsonl")
        let reader = scanner()
        _ = try reader.snapshot(weeklyWindow: window, quotaSampleAt: now)
        now.addTimeInterval(60)
        try write([token(100, 2), token(300, 3)], to: "a.jsonl")
        try write([token(200, 1), token(300, 3)], to: "b.jsonl")
        let old = try reader.snapshot(weeklyWindow: window, quotaSampleAt: now)
        XCTAssertEqual(old.weeklyQuotaCost?.scanStatus, .partial)
        let restarted = try reader.snapshot(weeklyWindow: window, invalidateWeeklyObservation: true, quotaSampleAt: now)
        XCTAssertEqual(restarted.diagnostics?.status, .partial)
        XCTAssertEqual(restarted.weeklyQuotaCost?.scanStatus, .complete)
        XCTAssertEqual(restarted.weeklyQuotaCost?.observedCostUSD, 0)
        XCTAssertNotEqual(restarted.weeklyQuotaCost?.observationStartIso, old.weeklyQuotaCost?.observationStartIso)
    }
}
