import Foundation
import XCTest
@testable import CodexRateLimitsCore

final class ScannerCompletenessTests: XCTestCase {
    private var root: URL!
    private var now = ISO8601DateFormatter().date(from: "2026-09-11T08:00:00Z")!
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ScannerCompleteness-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func scanner(_ roots: [URL]? = nil, weeklyRoots: [URL]? = nil) -> CodexBackend.LocalUsageScanner {
        CodexBackend.LocalUsageScanner(rootURLs: roots ?? [root], calendar: calendar, now: { self.now },
                                       cacheFileURL: root.appendingPathComponent("cache.json"), weeklyRootURLs: weeklyRoots)
    }

    private func events(total: Int = 100, model: String = "gpt-5.6-sol", complete: Bool = true) -> [[String: Any]] {
        var context: [String: Any] = ["model": model]
        var info: [String: Any] = ["total_token_usage": ["input_tokens": total, "total_tokens": total]]
        if complete {
            context["service_tier"] = "standard"
            info["last_token_usage"] = ["input_tokens": 1000]
        }
        return [["type": "session_meta", "payload": ["id": "session"], "timestamp": "2026-09-11T07:00:00Z"],
                ["type": "turn_context", "payload": context, "timestamp": "2026-09-11T07:00:00Z"],
                ["type": "event_msg", "payload": ["type": "token_count", "info": info], "timestamp": "2026-09-11T07:01:00Z"]]
    }

    private func write(_ events: [[String: Any]], to file: URL? = nil, spaced: Bool = false) throws {
        let file = file ?? root.appendingPathComponent("usage.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try events.map { event -> String in
            var line = String(decoding: try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]), as: UTF8.self)
            if spaced { line = line.replacingOccurrences(of: "\":", with: "\" :\t ").replacingOccurrences(of: ",", with: " , ") }
            return line
        }.joined(separator: "\n") + "\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    }

    func testJSONWhitespaceAndTypeAfterLargePayloadAreRecognized() throws {
        var lines = events()
        lines[2]["padding"] = String(repeating: "x", count: 4096)
        try write(lines, spaced: true)
        let spaced = try scanner().snapshot()
        XCTAssertEqual(spaced.totalTokens, 100)
        XCTAssertEqual(spaced.diagnostics?.status, .complete)
        try write(lines)
        let compact = try scanner().snapshot()
        XCTAssertEqual(spaced.todayCost?.estimatedCostUSD, compact.todayCost?.estimatedCostUSD)
        XCTAssertEqual(spaced.billingAssumptions?.assumedAPITokens, 0)
    }

    func testUnreadableSingleFileReportsIncompleteAndRecovers() throws {
        let file = root.appendingPathComponent("usage.jsonl")
        try write(events())
        let scanner = scanner()
        XCTAssertEqual(try scanner.snapshot().totalTokens, 100)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let failed = try scanner.snapshot()
        XCTAssertNotNil(failed.error)
        XCTAssertEqual(failed.totalTokens, 100)
        XCTAssertEqual(failed.diagnostics?.status, .partial)
        XCTAssertEqual(failed.diagnostics?.readFailureCount, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try write(events(total: 200))
        XCTAssertEqual(try scanner.snapshot().totalTokens, 200)
        XCTAssertNil(try scanner.snapshot().error)
    }

    func testEmptyUnavailableNoUsageAndConfirmedZeroAreDistinct() throws {
        XCTAssertEqual(try scanner().snapshot().diagnostics?.status, .empty)
        let missing = try scanner([root.appendingPathComponent("missing")]).snapshot()
        XCTAssertEqual(missing.diagnostics?.status, .unavailable)
        XCTAssertEqual(missing.diagnostics?.directoryFailureCount, 1)
        try write(Array(events().prefix(2)))
        XCTAssertEqual(try scanner().snapshot().diagnostics?.status, .noUsage)
        try write(events(total: 0))
        let zero = try scanner().snapshot()
        XCTAssertEqual(zero.totalTokens, 0)
        XCTAssertEqual(zero.diagnostics?.status, .complete)
        XCTAssertNil(zero.error)
    }

    func testDirectoryFailureRetainsTotalsAndRecoversIncludingNestedFolders() throws {
        let sessions = root.appendingPathComponent("sessions")
        let folder = sessions.appendingPathComponent("nested")
        let file = folder.appendingPathComponent("usage.jsonl")
        try write(events(), to: file)
        let scanner = scanner([sessions])
        XCTAssertEqual(try scanner.snapshot().totalTokens, 100)
        for directory in [folder, sessions] {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
            let failed = try scanner.snapshot()
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            XCTAssertEqual(failed.totalTokens, 100)
            XCTAssertEqual(failed.diagnostics?.status, .partial)
            XCTAssertGreaterThan(failed.diagnostics?.directoryFailureCount ?? 0, 0)
            XCTAssertNil(try scanner.snapshot().error)
        }
        try FileManager.default.removeItem(at: sessions)
        let missing = try scanner.snapshot()
        XCTAssertEqual(missing.totalTokens, 100)
        XCTAssertEqual(missing.diagnostics?.missingFileCount, 1)
        try write(events(total: 200), to: file)
        XCTAssertEqual(try scanner.snapshot().totalTokens, 200)
        XCTAssertNil(try scanner.snapshot().error)
    }

    func testMalformedAndInvalidUsageDiagnosticsPersistUntilTheFileIsRepaired() throws {
        let file = root.appendingPathComponent("usage.jsonl")
        try "{broken json}\nnot json\n".write(to: file, atomically: true, encoding: .utf8)
        let broken = try scanner().snapshot()
        XCTAssertEqual(broken.diagnostics?.status, .unavailable)
        XCTAssertEqual(broken.diagnostics?.parseErrorCount, 2)
        XCTAssertNotNil(broken.error)
        XCTAssertEqual(try scanner().snapshot().diagnostics?.parseErrorCount, 2)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(try scanner().snapshot().diagnostics?.missingFileCount, 1)
        var lines = events()
        lines[2]["timestamp"] = "not-a-timestamp"
        try write(lines)
        XCTAssertEqual(try scanner().snapshot().diagnostics?.skippedRecordCount, 1)
        for value: Any in [true, -1, 1e100, "unknown"] {
            lines = events()
            lines[2]["payload"] = ["type": "token_count", "info": ["total_token_usage": ["total_tokens": value]]]
            try write(lines)
            XCTAssertEqual(try scanner().snapshot().diagnostics?.skippedRecordCount, 1)
        }
        try write(events(total: 250))
        let repaired = try scanner().snapshot()
        XCTAssertEqual(repaired.totalTokens, 250)
        XCTAssertEqual(repaired.diagnostics?.status, .complete)
        XCTAssertEqual(repaired.parseErrorCount, 0)
    }

    func testPendingAndOversizedRecordsAreVisibleAndDoNotLoseTheFollowingEvent() throws {
        let file = root.appendingPathComponent("usage.jsonl")
        try write(Array(events().prefix(2)))
        let scanner = scanner()
        let event = try JSONSerialization.data(withJSONObject: events()[2], options: [.sortedKeys])
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: event.prefix(event.count / 2))
        XCTAssertEqual(try scanner.snapshot().diagnostics?.pendingRecordCount, 1)
        try handle.write(contentsOf: event.dropFirst(event.count / 2) + Data([0x0A]))
        XCTAssertEqual(try scanner.snapshot().totalTokens, 100)
        XCTAssertEqual(try scanner.snapshot().diagnostics?.status, .complete)
        try handle.write(contentsOf: Data("{\"type\":\"event_msg\",\"padding\":\"".utf8) + Data(repeating: 0x78, count: 9 * 1024 * 1024))
        XCTAssertEqual(try scanner.snapshot().diagnostics?.skippedRecordCount, 1)
        try handle.write(contentsOf: Data("\"}\n".utf8))
        var next = events(total: 200)[2]
        next["timestamp"] = "2026-09-11T07:02:00Z"
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: next) + Data([0x0A]))
        let result = try scanner.snapshot()
        XCTAssertEqual(result.totalTokens, 200)
        XCTAssertEqual(result.diagnostics?.skippedRecordCount, 1)
        XCTAssertEqual(result.diagnostics?.pendingRecordCount, 0)
        XCTAssertEqual(try self.scanner().snapshot().diagnostics?.skippedRecordCount, 1)
    }

    func testPricingCoverageAndAssumptionsAreIndependentAndCopiesDoNotDoubleCount() throws {
        try write(events(complete: false))
        try write(events(complete: false), to: root.appendingPathComponent("copy.jsonl"))
        let result = try scanner().snapshot()
        XCTAssertEqual(result.diagnostics?.status, .complete)
        XCTAssertEqual(result.todayCost?.coveragePercent, 100)
        XCTAssertEqual(result.billingAssumptions?.totalTokens, 100)
        XCTAssertEqual(result.billingAssumptions?.missingRequestContextTokens, 100)
        XCTAssertEqual(result.billingAssumptions?.missingServiceTierTokens, 100)
        XCTAssertEqual(result.billingAssumptions?.apiPercent, 100)
        XCTAssertEqual(result.billingAssumptions?.creditPercent, 100)
        var astra = events(model: "gpt-6-astra", complete: false)
        astra[1]["payload"] = ["model": "gpt-6-astra", "service_tier": "standard"]
        try write(astra)
        try FileManager.default.removeItem(at: root.appendingPathComponent("copy.jsonl"))
        // Restore the copy with the same contents so group ownership is verified.
        try write(astra, to: root.appendingPathComponent("copy.jsonl"))
        let knownMode = try scanner().snapshot()
        XCTAssertEqual(knownMode.billingAssumptions?.assumedAPITokens, 100)
        XCTAssertEqual(knownMode.billingAssumptions?.assumedCreditTokens, 0)
    }

    func testMissingInputFieldDoesNotBecomeAKnownZeroContext() throws {
        var lines = events()
        var payload = lines[2]["payload"] as! [String: Any]
        var info = payload["info"] as! [String: Any]
        info["last_token_usage"] = ["output_tokens": 10]
        payload["info"] = info
        lines[2]["payload"] = payload
        try write(lines)
        XCTAssertEqual(try scanner().snapshot().billingAssumptions?.missingRequestContextTokens, 100)
    }

    func testWeeklyInferencePausesAndRecoversWithoutResettingBaseline() throws {
        let file = root.appendingPathComponent("usage.jsonl")
        try write(Array(events().prefix(2)))
        let scanner = scanner()
        func window(_ used: Int) -> RateLimitWindow {
            RateLimitWindow(usedPercent: used, remainingPercent: 100 - used, windowDurationMins: 10080,
                            resetsAt: 1_789_632_000, resetsAtIso: nil)
        }
        let before = try scanner.snapshot(weeklyWindow: window(10))
        now.addTimeInterval(120)
        var lines = events(total: 100_000)
        lines[2]["timestamp"] = "2026-09-11T08:01:00Z"
        try write(lines)
        XCTAssertNotNil(try scanner.snapshot(weeklyWindow: window(15)).weeklyQuotaCost?.estimatedQuotaUSD)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        let failed = try scanner.snapshot(weeklyWindow: window(15))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertNil(failed.weeklyQuotaCost?.estimatedQuotaUSD)
        XCTAssertEqual(failed.weeklyQuotaCost?.inferencePauseReason, "incompleteScan")
        let recovered = try scanner.snapshot(weeklyWindow: window(15))
        XCTAssertNotNil(recovered.weeklyQuotaCost?.estimatedQuotaUSD)
        XCTAssertEqual(recovered.weeklyQuotaCost?.observationStartIso, before.weeklyQuotaCost?.observationStartIso)
        var missing = events(total: 100_000, complete: false)
        missing[2]["timestamp"] = "2026-09-11T08:01:00Z"
        try write(missing)
        let assumed = try scanner.snapshot(weeklyWindow: window(15))
        XCTAssertEqual(assumed.weeklyQuotaCost?.inferencePauseReason, "billingAssumptions")
        XCTAssertEqual(assumed.weeklyQuotaCost?.coveragePercent, 100)
        XCTAssertNil(assumed.weeklyQuotaCost?.estimatedQuotaUSD)
        XCTAssertEqual(assumed.weeklyQuotaCost?.observationStartIso, before.weeklyQuotaCost?.observationStartIso)
    }

    func testOtherHomesReadFailureDoesNotBlockAnIndependentWeeklyEstimate() throws {
        let active = root.appendingPathComponent("active"), other = root.appendingPathComponent("other")
        let activeFile = active.appendingPathComponent("a.jsonl"), otherFile = other.appendingPathComponent("b.jsonl")
        try write(Array(events().prefix(2)), to: activeFile)
        var otherLines = events()
        otherLines[0]["payload"] = ["id": "other-session"]
        try write(otherLines, to: otherFile)
        let scanner = scanner([active, other], weeklyRoots: [active])
        var window = RateLimitWindow(usedPercent: 10, remainingPercent: 90, windowDurationMins: 10080,
                                     resetsAt: 1_789_632_000, resetsAtIso: nil)
        _ = try scanner.snapshot(weeklyWindow: window)
        now.addTimeInterval(120)
        var lines = events(total: 100_000)
        lines[2]["timestamp"] = "2026-09-11T08:01:00Z"
        try write(lines, to: activeFile)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: otherFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: otherFile.path) }
        window = RateLimitWindow(usedPercent: 15, remainingPercent: 85, windowDurationMins: 10080,
                                 resetsAt: 1_789_632_000, resetsAtIso: nil)
        let result = try scanner.snapshot(weeklyWindow: window)
        XCTAssertEqual(result.diagnostics?.status, .partial)
        XCTAssertEqual(result.weeklyQuotaCost?.scanStatus, .complete)
        XCTAssertNotNil(result.weeklyQuotaCost?.estimatedQuotaUSD)
    }

    func testLargeMetadataCopiesAndEscapedJSONKeysAreRecognizedOnTheFirstScan() throws {
        var lines = events()
        lines[0]["padding"] = String(repeating: "x", count: 2 * 1024 * 1024)
        try write(lines)
        try write(lines, to: root.appendingPathComponent("copy.jsonl"))
        let result = try scanner().snapshot()
        XCTAssertEqual(result.totalTokens, 100)
        XCTAssertEqual(result.diagnostics?.status, .complete)
        let file = root.appendingPathComponent("usage.jsonl")
        let encoded = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: "\"type\":", with: "\"ty\\u0070e\" : ")
            .replacingOccurrences(of: "\"token_count\"", with: "\"token_\\u0063ount\"")
        try encoded.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try scanner().snapshot().totalTokens, 100)
    }

    func testOptionalMissingRootsAndRateOnlyUpdatesAreNotFailures() throws {
        let optional = root.appendingPathComponent("optional")
        let scanner = CodexBackend.LocalUsageScanner(rootURLs: [root, optional], calendar: calendar, now: { self.now },
                                                     allowMissingRoots: true)
        try write([["type": "event_msg", "payload": ["type": "token_count", "info": NSNull(), "rate_limits": [:]]]])
        let result = try scanner.snapshot()
        XCTAssertEqual(result.diagnostics?.status, .noUsage)
        XCTAssertEqual(result.diagnostics?.roots.last?.state, .missing)
        XCTAssertNil(result.error)
    }

    func testLegacyParserMigrationRecoversSkippedJSONWithoutChangingWeeklyBaseline() throws {
        let file = root.appendingPathComponent("usage.jsonl")
        try write(Array(events().prefix(2)))
        let scanner = scanner()
        let window = RateLimitWindow(usedPercent: 10, remainingPercent: 90, windowDurationMins: 10080,
                                     resetsAt: 1_789_632_000, resetsAtIso: nil)
        let baseline = try scanner.snapshot(weeklyWindow: window)
        now.addTimeInterval(120)
        var lines = events(total: 100_000)
        lines[2]["timestamp"] = "2026-09-11T08:01:00Z"
        try write(lines, spaced: true)
        _ = try scanner.snapshot(weeklyWindow: window)
        let cacheURL = root.appendingPathComponent("cache.json")
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as! [String: Any]
        var cache = document["cache"] as! [String: Any]
        var files = cache["files"] as! [String: [String: Any]]
        var state = files[file.path]!
        state["diagnostics"] = nil
        var totals = state["totals"] as! [String: Any]
        totals["totalTokens"] = 0
        state["totals"] = totals
        files[file.path] = state
        cache["files"] = files
        document["cache"] = cache
        try JSONSerialization.data(withJSONObject: document).write(to: cacheURL, options: .atomic)
        let recovered = try self.scanner().snapshot(weeklyWindow: window)
        XCTAssertEqual(recovered.totalTokens, 100_000)
        XCTAssertEqual(recovered.diagnostics?.status, .complete)
        XCTAssertEqual(recovered.weeklyQuotaCost?.observationStartIso, baseline.weeklyQuotaCost?.observationStartIso)
        XCTAssertEqual(recovered.weeklyQuotaCost?.observedCostUSD, 0.4)
    }
}
