import Foundation
import XCTest
@testable import CodexRateLimitsCore

final class ScannerIdentityTests: XCTestCase {
    private var root: URL!
    private var now = ISO8601DateFormatter().date(from: "2026-09-11T08:00:00Z")!
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ScannerIdentity-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func scanner(_ roots: [URL]? = nil, weeklyRoots: [URL]? = nil) -> CodexBackend.LocalUsageScanner {
        CodexBackend.LocalUsageScanner(rootURLs: roots ?? [root], calendar: calendar, now: { self.now },
                                       cacheFileURL: root.appendingPathComponent("cache.json"), weeklyRootURLs: weeklyRoots)
    }

    private func events(id: String = "session-a", total: Int, second: Int = 1) -> [[String: Any]] {
        [["timestamp": "2026-09-11T07:00:00Z", "type": "session_meta", "payload": ["id": id]],
         ["timestamp": "2026-09-11T07:00:00Z", "type": "turn_context", "payload": ["model": "gpt-5.6-sol"]],
         token(total, second: second)]
    }

    private func token(_ total: Int, second: Int) -> [String: Any] {
        ["timestamp": String(format: "2026-09-11T08:00:%02dZ", second), "type": "event_msg",
         "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": total, "total_tokens": total]]]]
    }

    private func data(_ events: [[String: Any]]) throws -> Data {
        try events.reduce(into: Data()) { value, event in
            value.append(try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])); value.append(0x0A)
        }
    }

    private func write(_ events: [[String: Any]], to file: URL, atomic: Bool = false) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data(events).write(to: file, options: atomic ? .atomic : [])
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    }

    func testSameSizeReplacementAndInPlaceRewriteInvalidateCachedTotals() throws {
        let file = root.appendingPathComponent("rollout.jsonl")
        try write(events(total: 100), to: file)
        let scanner = scanner()
        XCTAssertEqual(try scanner.snapshot().totalTokens, 100)
        try write(events(total: 900), to: file, atomic: true)
        XCTAssertEqual(try scanner.snapshot().totalTokens, 900)
        try write(events(total: 300), to: file)
        XCTAssertEqual(try self.scanner().snapshot().totalTokens, 300)
    }

    func testTruncateAndRewritePastPreviousCursorRebuildsTheWholeFile() throws {
        let file = root.appendingPathComponent("rollout.jsonl")
        try write(events(total: 100), to: file)
        let scanner = scanner()
        _ = try scanner.snapshot()
        try write(events(total: 900) + [token(1000, second: 2)], to: file)
        XCTAssertEqual(try scanner.snapshot().totalTokens, 1000)
        XCTAssertEqual(try self.scanner().snapshot().totalTokens, 1000)
    }

    func testRenamedCopiesDeduplicateBySessionAndDistinctSessionsWithSameFilenameSurvive() throws {
        let a = root.appendingPathComponent("a/rollout.jsonl")
        let b = root.appendingPathComponent("b/rollout.jsonl")
        try write(events(total: 100), to: a)
        try write(events(id: "session-b", total: 200), to: b)
        try write(events(total: 100), to: root.appendingPathComponent("renamed-copy.jsonl"))
        XCTAssertEqual(try scanner().snapshot().totalTokens, 300)
    }

    func testDivergentCopiesCountSharedHistoryOnceAndEachDistinctTail() throws {
        try write(events(total: 100) + [token(200, second: 2)], to: root.appendingPathComponent("a.jsonl"))
        try write(events(total: 100) + [token(250, second: 3)], to: root.appendingPathComponent("b.jsonl"))
        let scanner = scanner()
        let initial = try scanner.snapshot()
        XCTAssertEqual(initial.totalTokens, 350)
        XCTAssertEqual(initial.todayCost?.estimatedCostUSD ?? -1, 0.0014, accuracy: 0.0000001)
        try write(events(total: 100) + [token(250, second: 3), token(300, second: 4)], to: root.appendingPathComponent("b.jsonl"))
        XCTAssertEqual(try scanner.snapshot().totalTokens, 400)
        XCTAssertEqual(try self.scanner().snapshot().totalTokens, 400)
    }

    func testArchiveMoveWithNewFilenameDoesNotRetainDuplicateCachedUsage() throws {
        let original = root.appendingPathComponent("sessions/original.jsonl")
        let archive = root.appendingPathComponent("archive/renamed.jsonl")
        try write(events(total: 100), to: original)
        let scanner = scanner()
        XCTAssertEqual(try scanner.snapshot().totalTokens, 100)
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: archive)
        XCTAssertEqual(try scanner.snapshot().totalTokens, 100)
        XCTAssertEqual(try self.scanner().snapshot().totalTokens, 100)
    }

    func testCrossHomeCopiesPreserveWeeklySourcesAndDivergentTails() throws {
        let outside = root.appendingPathComponent("a-other")
        let active = root.appendingPathComponent("z-active")
        let outsideFile = outside.appendingPathComponent("same.jsonl")
        let activeFile = active.appendingPathComponent("same.jsonl")
        try write(Array(events(total: 100_000).prefix(2)), to: outsideFile)
        try write(Array(events(total: 100_000).prefix(2)), to: activeFile)
        let scanner = scanner([outside, active], weeklyRoots: [active])
        func window(_ used: Int) -> RateLimitWindow {
            RateLimitWindow(usedPercent: used, remainingPercent: 100 - used, windowDurationMins: 10080,
                            resetsAt: 1_789_632_000, resetsAtIso: nil)
        }
        let baseline = try scanner.snapshot(weeklyWindow: window(10))
        now.addTimeInterval(120)
        try write(events(total: 100_000) + [["type": "response_item", "payload": ["text": "padding"]]], to: outsideFile)
        try write(events(total: 100_000), to: activeFile)
        let copied = try scanner.snapshot(weeklyWindow: window(15))
        XCTAssertEqual(copied.totalTokens, 100_000)
        XCTAssertEqual(copied.weeklyQuotaCost?.observedCostUSD, 0.4)
        XCTAssertEqual(copied.topFiles?.first?.sourceFiles?.count, 2)
        XCTAssertEqual(copied.weeklyQuotaCost?.observationStartIso, baseline.weeklyQuotaCost?.observationStartIso)
        try write(events(total: 100_000) + [token(150_000, second: 3)], to: activeFile)
        let otherTail = events(total: 100_000) + [token(200_000, second: 4)]
        try write(otherTail, to: outsideFile)
        let diverged = try scanner.snapshot(weeklyWindow: window(20))
        XCTAssertEqual(diverged.totalTokens, 250_000)
        XCTAssertEqual(diverged.weeklyQuotaCost?.observedCostUSD ?? -1, 0.6, accuracy: 0.000001)
        try FileManager.default.removeItem(at: outsideFile)
        try write(events(total: 100_000) + [token(150_000, second: 3), token(200_000, second: 5)], to: activeFile)
        let missing = try scanner.snapshot(weeklyWindow: window(20))
        XCTAssertEqual(missing.totalTokens, 250_000)
        XCTAssertNotNil(missing.error)
        try write(otherTail, to: outsideFile)
        let restored = try scanner.snapshot(weeklyWindow: window(20))
        XCTAssertEqual(restored.totalTokens, 300_000)
        XCTAssertNil(restored.error)
    }

    func testRebuildRepairsCachedTotalsAndPreservesAccountObservation() throws {
        let file = root.appendingPathComponent("rollout.jsonl")
        try write(Array(events(total: 100_000).prefix(2)), to: file)
        let scanner = scanner()
        let context = CodexAccountContext(codexHome: root.path, authenticationSource: "fixture", accountKey: "a",
                                          accountLabel: nil, limitID: "codex")
        let window = RateLimitWindow(usedPercent: 10, remainingPercent: 90, windowDurationMins: 10080,
                                     resetsAt: 1_789_632_000, resetsAtIso: nil)
        let before = try scanner.snapshot(weeklyWindow: window, accountContext: context)
        now.addTimeInterval(120)
        try write(events(total: 100_000), to: file)
        _ = try scanner.snapshot(weeklyWindow: window, accountContext: context)
        let cacheURL = root.appendingPathComponent("cache.json")
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        var cache = try XCTUnwrap(document["cache"] as? [String: Any])
        var files = try XCTUnwrap(cache["files"] as? [String: [String: Any]])
        let path = try XCTUnwrap(files.keys.first)
        var totals = try XCTUnwrap(files[path]?["totals"] as? [String: Any])
        totals["totalTokens"] = 1
        files[path]?["totals"] = totals
        cache["files"] = files
        document["cache"] = cache
        try JSONSerialization.data(withJSONObject: document).write(to: cacheURL, options: .atomic)
        XCTAssertEqual(try scanner.snapshot(weeklyWindow: window, accountContext: context).totalTokens, 1)
        let rebuilt = try scanner.snapshot(weeklyWindow: window, accountContext: context, rebuild: true)
        XCTAssertEqual(rebuilt.totalTokens, 100_000)
        XCTAssertEqual(rebuilt.weeklyQuotaCost?.observedCostUSD, 0.4)
        XCTAssertEqual(rebuilt.weeklyQuotaCost?.accountScopeKey, before.weeklyQuotaCost?.accountScopeKey)
        XCTAssertEqual(rebuilt.weeklyQuotaCost?.observationStartIso, before.weeklyQuotaCost?.observationStartIso)
        XCTAssertEqual(rebuilt.weeklyQuotaCost?.baselineUsedPercent, before.weeklyQuotaCost?.baselineUsedPercent)
        XCTAssertEqual(try self.scanner().snapshot().totalTokens, 100_000)
    }

    func testMiddleOfPrefixRewriteIsDetectedEvenWhenFileAlsoGrows() throws {
        let file = root.appendingPathComponent("rollout.jsonl")
        let padding: [String: Any] = ["type": "response_item", "payload": ["text": String(repeating: "x", count: 16_384)]]
        var lines = events(total: 100)
        lines.insert(padding, at: 1)
        lines.insert(padding, at: 3)
        try write(lines, to: file)
        let scanner = scanner()
        XCTAssertEqual(try scanner.snapshot().todayCost?.coveragePercent, 100)
        lines[2]["payload"] = ["model": "gpt-5.6-abc"]
        try write(lines + [token(200, second: 2)], to: file)
        let result = try scanner.snapshot()
        XCTAssertEqual(result.totalTokens, 200)
        XCTAssertEqual(result.todayCost?.coveragePercent, 0)
        XCTAssertNil(result.todayCost?.estimatedCostUSD)
    }

    func testUnreadableCopyDoesNotPartiallyReplaceVerifiedGroupTotals() throws {
        let a = root.appendingPathComponent("a.jsonl"), b = root.appendingPathComponent("b.jsonl")
        try write(events(total: 100), to: a)
        try write(events(total: 100), to: b)
        let scanner = scanner()
        XCTAssertEqual(try scanner.snapshot().totalTokens, 100)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: a.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: a.path) }
        try write(events(total: 100) + [token(200, second: 2)], to: b)
        let result = try scanner.snapshot()
        XCTAssertEqual(result.totalTokens, 100)
        XCTAssertNotNil(result.error)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: a.path)
        XCTAssertEqual(try scanner.snapshot().totalTokens, 200)
        try write(events(total: 100), to: a, atomic: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: a.path)
        try write(events(total: 100) + [token(200, second: 2), token(300, second: 3)], to: b)
        let replacement = try scanner.snapshot()
        XCTAssertEqual(replacement.totalTokens, 200)
        XCTAssertNotNil(replacement.error)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: a.path)
        XCTAssertEqual(try scanner.snapshot().totalTokens, 300)
    }

    func testDuplicateCopiesCarryBaselinesAcrossMidnight() throws {
        let a = root.appendingPathComponent("a.jsonl"), b = root.appendingPathComponent("b.jsonl")
        try write(events(total: 100), to: a)
        try write(events(total: 100), to: b)
        let scanner = scanner()
        XCTAssertEqual(try scanner.snapshot().totalTokens, 100)
        now.addTimeInterval(86400)
        var next = token(250, second: 1)
        next["timestamp"] = "2026-09-12T07:00:00Z"
        try write(events(total: 100) + [next], to: b)
        XCTAssertEqual(try scanner.snapshot().totalTokens, 150)
        XCTAssertEqual(try self.scanner().snapshot().totalTokens, 150)
        var appended = token(300, second: 2)
        appended["timestamp"] = "2026-09-12T08:00:00Z"
        try write(events(total: 100) + [next, appended], to: b)
        let incremental = try scanner.snapshot()
        XCTAssertEqual(incremental.totalTokens, 200)
        let rebuilt = try scanner.snapshot(rebuild: true)
        XCTAssertEqual(rebuilt.totalTokens, incremental.totalTokens)
        XCTAssertEqual(rebuilt.todayCost?.estimatedCostUSD, incremental.todayCost?.estimatedCostUSD)
        XCTAssertEqual(rebuilt.todayCredits?.estimatedCredits, incremental.todayCredits?.estimatedCredits)
    }

    func testLegacyArchivedHistoryWithoutCurrentContributionsDoesNotBlockRebuild() throws {
        let file = root.appendingPathComponent("original.jsonl")
        try write(events(total: 100), to: file)
        XCTAssertEqual(try scanner().snapshot().totalTokens, 100)
        let cacheURL = root.appendingPathComponent("cache.json")
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        var cache = try XCTUnwrap(document["cache"] as? [String: Any])
        var files = try XCTUnwrap(cache["files"] as? [String: [String: Any]])
        for key in ["fileStamp", "prefixDigest", "latestUsageAt", "hasUsageBounds"] { files[file.path]?[key] = nil }
        cache["files"] = files
        document["cache"] = cache
        try JSONSerialization.data(withJSONObject: document).write(to: cacheURL, options: .atomic)
        now.addTimeInterval(86400)
        var next = token(250, second: 1)
        next["timestamp"] = "2026-09-12T07:00:00Z"
        try write(events(total: 100) + [next], to: root.appendingPathComponent("archive/renamed.jsonl"))
        try FileManager.default.removeItem(at: file)
        let rebuilt = try scanner().snapshot(rebuild: true)
        XCTAssertEqual(rebuilt.totalTokens, 150)
        XCTAssertNil(rebuilt.error)
    }

    func testCopiesWithMissingIntermediateSamplesAreIndependentOfFileOrder() throws {
        let shorter = events(total: 100) + [token(300, second: 3)]
        let complete = events(total: 100) + [token(200, second: 2), token(300, second: 3)]
        let a = root.appendingPathComponent("a.jsonl"), b = root.appendingPathComponent("b.jsonl")
        try write(shorter, to: a)
        try write(complete, to: b)
        let scanner = scanner()
        XCTAssertEqual(try scanner.snapshot().totalTokens, 300)
        try write(complete, to: a)
        try write(shorter, to: b)
        XCTAssertEqual(try scanner.snapshot().totalTokens, 300)
    }
}
