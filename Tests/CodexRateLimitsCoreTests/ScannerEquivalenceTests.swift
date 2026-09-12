import Foundation
import XCTest
@testable import CodexRateLimitsCore

/// Separate persistent caches follow the same file history. The reference
/// replays every time; the subject appends incrementally and restarts midstream.
final class ScannerEquivalenceTests: XCTestCase {
    private var root: URL!
    private var now = ISO8601DateFormatter().date(from: "2026-09-11T15:58:00Z")!
    private var pricing = PricingCatalog.builtin
    private var sessions: URL { root.appendingPathComponent("sessions") }
    private var archive: URL { root.appendingPathComponent("archive") }
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ScannerEquivalence-\(UUID())")
        for directory in [sessions, archive] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func scanner(_ name: String) -> CodexBackend.LocalUsageScanner {
        CodexBackend.LocalUsageScanner(rootURLs: [sessions, archive], calendar: calendar, now: { self.now },
            cacheFileURL: root.appendingPathComponent("\(name).json"), pricingProvider: { self.pricing })
    }
    private func meta(_ id: String) -> [String: Any] { ["type": "session_meta", "payload": ["id": id]] }
    private func model(_ name: String) -> [String: Any] { ["type": "turn_context", "payload": ["model": name, "service_tier": "standard"]] }
    private func token(_ total: Int, delta: Int) -> [String: Any] {
        ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: now),
         "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": total, "total_tokens": total],
                                                     "last_token_usage": ["input_tokens": delta, "total_tokens": delta]]]]
    }
    private func write(_ events: [[String: Any]], to file: URL, append: Bool = false) throws {
        var data = Data()
        for event in events { data.append(try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])); data.append(10) }
        if append {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        } else { try data.write(to: file, options: .atomic) }
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    }
    private func read(_ scanner: CodexBackend.LocalUsageScanner, rebuild: Bool = false) throws -> LocalUsageSnapshot {
        let context = CodexAccountContext(codexHome: root.path, authenticationSource: "fixture", accountKey: "a", accountLabel: nil, limitID: "codex")
        let window = RateLimitWindow(usedPercent: 20, remainingPercent: 80, windowDurationMins: 10080, resetsAt: nil, resetsAtIso: "2026-09-17T16:00:00Z")
        return try scanner.snapshot(weeklyWindow: window, accountContext: context, rebuild: rebuild, quotaSampleAt: now)
    }
    private func assertEquivalent(_ subject: CodexBackend.LocalUsageScanner, _ reference: CodexBackend.LocalUsageScanner,
                                  total: Int64, stage: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try read(subject)
        let replay = try read(reference, rebuild: true)
        XCTAssertNotNil(actual.weeklyQuotaCost, "Weekly evidence must participate in the comparison", file: file, line: line)
        XCTAssertEqual(actual.totalTokens, total, stage, file: file, line: line)
        XCTAssertEqual(replay.totalTokens, total, stage, file: file, line: line)
        XCTAssertEqual(try stableJSON(actual), try stableJSON(replay), stage, file: file, line: line)
        let restarted = try read(scanner("incremental"))
        XCTAssertEqual(try stableJSON(actual), try stableJSON(restarted), "restart: \(stage)", file: file, line: line)
    }
    private func stableJSON(_ snapshot: LocalUsageSnapshot) throws -> String {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        // Age uses the wall clock at serialization. All data/sample/attempt times,
        // diagnostics, exact model names, prices and weekly evidence still compare.
        var freshness = value["freshness"] as? [String: Any]
        freshness?.removeValue(forKey: "ageSeconds")
        value["freshness"] = freshness
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    func testMidnightForkCopyArchiveAndRestartMatchFullReplay() throws {
        var subject = scanner("incremental")
        let reference = scanner("reference")
        try assertEquivalent(subject, reference, total: 0, stage: "empty baseline")
        let file = sessions.appendingPathComponent("parent.jsonl")
        try write([meta("parent"), model("gpt-5.6-sol"), token(100, delta: 100)], to: file)
        try assertEquivalent(subject, reference, total: 100, stage: "initial")
        now.addTimeInterval(60)
        try write([token(150, delta: 50)], to: file, append: true)
        let copy = sessions.appendingPathComponent("renamed-copy.jsonl")
        try FileManager.default.copyItem(at: file, to: copy)
        try assertEquivalent(subject, reference, total: 150, stage: "copy deduplicated")
        now.addTimeInterval(120) // Shanghai midnight; both caches retain yesterday's baseline.
        try write([token(220, delta: 70)], to: file, append: true)
        try assertEquivalent(subject, reference, total: 70, stage: "midnight and divergent tail")
        let moved = archive.appendingPathComponent("new-name.jsonl")
        try FileManager.default.moveItem(at: file, to: moved)
        try assertEquivalent(subject, reference, total: 70, stage: "archive move")
        now.addTimeInterval(60)
        let fork = sessions.appendingPathComponent("fork.jsonl")
        try write([meta("fork"), model("gpt-5.6-sol"), meta("parent"), token(220, delta: 220),
                   meta("fork"), token(250, delta: 30)], to: fork)
        try assertEquivalent(subject, reference, total: 100, stage: "fork import excluded")
        subject = scanner("incremental")
        now.addTimeInterval(60)
        try write([token(250, delta: 30)], to: moved, append: true)
        try write([token(270, delta: 20)], to: fork, append: true)
        try assertEquivalent(subject, reference, total: 150, stage: "append after restart")
        XCTAssertEqual(try read(subject).todayCost?.estimatedCostUSD ?? -1, 0.0006, accuracy: 1e-12)
        XCTAssertEqual(try read(subject).todayCredits?.estimatedCredits ?? -1, 0.015, accuracy: 1e-12)
    }

    func testLegacyRootAliasesPreserveTheObservationWhenCanonicalPathsChange() throws {
        let subject = scanner("incremental")
        let original = try read(subject)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let cacheURL = root.appendingPathComponent("incremental.json")
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        var cache = try XCTUnwrap(document["cache"] as? [String: Any])
        let paths = [alias.appendingPathComponent("sessions").path, alias.appendingPathComponent("archive").path]
        cache["source"] = paths.joined(separator: ",")
        cache["rootPaths"] = paths
        var observation = try XCTUnwrap(cache["weeklyCostObservation"] as? [String: Any])
        observation["rootPaths"] = paths
        cache["weeklyCostObservation"] = observation
        document["cache"] = cache
        try JSONSerialization.data(withJSONObject: document).write(to: cacheURL, options: .atomic)
        now.addTimeInterval(60)
        let migrated = try read(scanner("incremental"))
        XCTAssertEqual(migrated.weeklyQuotaCost?.observationStartIso, original.weeklyQuotaCost?.observationStartIso)
        XCTAssertEqual(migrated.weeklyQuotaCost?.accountScopeKey, original.weeklyQuotaCost?.accountScopeKey)
        XCTAssertEqual(migrated.totalTokens, original.totalTokens)
    }

    func testReplacementPartialLineRepairAndPriceMigrationMatchFullReplay() throws {
        let subject = scanner("incremental"), reference = scanner("reference")
        try assertEquivalent(subject, reference, total: 0, stage: "empty baseline")
        let file = sessions.appendingPathComponent("usage.jsonl")
        try write([meta("a"), model("gpt-5.6-sol"), token(100, delta: 100)], to: file)
        try assertEquivalent(subject, reference, total: 100, stage: "initial")
        let size = try Data(contentsOf: file).count
        try write([meta("a"), model("gpt-5.6-sol"), token(900, delta: 900)], to: file)
        XCTAssertEqual(try Data(contentsOf: file).count, size)
        try assertEquivalent(subject, reference, total: 900, stage: "same size atomic replacement")
        now.addTimeInterval(1)
        try write([model("Private-Raw-Model")], to: file, append: true)
        let pending = try JSONSerialization.data(withJSONObject: token(950, delta: 50))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: pending); try handle.close()
        try assertEquivalent(subject, reference, total: 900, stage: "pending record")
        let finish = try FileHandle(forWritingTo: file)
        try finish.seekToEnd(); try finish.write(contentsOf: Data([10])); try finish.close()
        try assertEquivalent(subject, reference, total: 950, stage: "completed unknown record")
        XCTAssertEqual(try read(subject).todayCost?.unpricedTokens, 50)
        var document = pricing.document
        document.api.version = "fixture-api-v2"
        document.api.aliases["private-raw-model"] = "gpt-5.6-sol"
        document.api.models["gpt-5.6-sol"]?.input = 8
        document.credits.version = "fixture-credits-v2"
        document.credits.aliases["private-raw-model"] = "gpt-5.6-sol"
        pricing = PricingCatalog.snapshot(try PricingCatalog.decode(JSONEncoder().encode(document)), source: "custom", path: "/fixture/pricing.json", error: nil)
        try assertEquivalent(subject, reference, total: 950, stage: "price migration")
        XCTAssertEqual(try read(subject).todayCost?.estimatedCostUSD ?? -1, 0.0076, accuracy: 1e-12)
        XCTAssertEqual(try read(subject).todayCost?.unpricedTokens, 0)
        let bad = sessions.appendingPathComponent("bad.jsonl")
        try Data("{broken}\n".utf8).write(to: bad)
        try assertEquivalent(subject, reference, total: 950, stage: "incomplete scan")
        XCTAssertEqual(try read(subject).diagnostics?.status, .partial)
        try write([meta("b"), model("gpt-5.6-sol"), token(25, delta: 25)], to: bad)
        try assertEquivalent(subject, reference, total: 975, stage: "repaired log")
        XCTAssertNil(try read(subject).error)
    }
}
