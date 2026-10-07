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

    private func scanner(_ name: String) -> LocalUsageScanner {
        LocalUsageScanner(rootURLs: [sessions, archive], calendar: calendar, now: { self.now },
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
    private func read(_ scanner: LocalUsageScanner, rebuild: Bool = false) throws -> LocalUsageSnapshot {
        let context = CodexAccountContext(codexHome: root.path, authenticationSource: "fixture", accountKey: "a", accountLabel: nil, limitID: "codex")
        let window = RateLimitWindow(usedPercent: 20, remainingPercent: 80, windowDurationMins: 10080, resetsAt: nil, resetsAtIso: "2026-09-17T16:00:00Z")
        return try scanner.snapshot(weeklyWindow: window, accountContext: context, rebuild: rebuild, quotaSampleAt: now)
    }
    private func assertEquivalent(_ subject: LocalUsageScanner, _ reference: LocalUsageScanner,
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
        // Age uses the wall clock at serialization. File ranking ties and the
        // last floating-point bits of sums can depend on dictionary iteration.
        var freshness = value["freshness"] as? [String: Any]
        freshness?.removeValue(forKey: "ageSeconds")
        value["freshness"] = freshness
        if let files = value["topFiles"] as? [[String: Any]] {
            value["topFiles"] = files.sorted {
                let a = $0["totalTokens"] as? Int64 ?? 0, b = $1["totalTokens"] as? Int64 ?? 0
                return a == b ? ($0["file"] as? String ?? "") < ($1["file"] as? String ?? "") : a > b
            }
        }
        func normalizeAmounts(_ value: Any, key: String = "") -> Any {
            if let object = value as? [String: Any] {
                return object.reduce(into: [String: Any]()) { result, entry in
                    result[entry.key] = normalizeAmounts(entry.value, key: entry.key)
                }
            }
            if let values = value as? [Any] { return values.map { normalizeAmounts($0) } }
            if ["estimatedCostUSD", "estimatedCredits", "observedCostUSD"].contains(key), let amount = value as? Double {
                return (amount * 1e12).rounded() / 1e12
            }
            return value
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: normalizeAmounts(value), options: [.sortedKeys]), as: UTF8.self)
    }

    func testCreditAccountingMigrationPreservesAPIAndWeeklyEvidence() throws {
        now = ISO8601DateFormatter().date(from: "2026-09-11T04:00:00Z")!
        var oldDocument = PricingCatalog.builtin.document
        oldDocument.credits.version = "2026-10-06.1"
        for model in oldDocument.credits.models.keys {
            oldDocument.credits.models[model]?.cacheWriteInputUnverified = nil
            oldDocument.credits.models[model]?.maximumInputTokens = nil
        }
        oldDocument.credits.models["gpt-5.6-sol"]?.contextTier = .init(threshold: 272_000, inputMultiplier: 2, outputMultiplier: 1.5)
        let legacy = PricingCatalog.snapshot(oldDocument, source: "custom", path: nil, error: nil)
        pricing = legacy
        var subject = scanner("incremental")
        let reference = scanner("reference")
        try assertEquivalent(subject, reference, total: 0, stage: "baseline")
        now.addTimeInterval(60)
        func sample(_ input: Int, _ writes: Int = 0) -> [String: Any] {
            let usage = ["input_tokens": input, "cache_write_input_tokens": writes, "total_tokens": input]
            return ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: now),
                    "payload": ["type": "token_count", "info": ["total_token_usage": usage, "last_token_usage": usage]]]
        }
        try write([meta("writes"), model("gpt-6.1-sol"), sample(100_000, 100_000)], to: sessions.appendingPathComponent("writes.jsonl"))
        try write([meta("long"), model("gpt-5.6-sol"), sample(272_001)], to: sessions.appendingPathComponent("long.jsonl"))
        try write([meta("known"), model("gpt-6.1-sol"), sample(100_000)], to: sessions.appendingPathComponent("known.jsonl"))
        try assertEquivalent(subject, reference, total: 472_001, stage: "legacy credits")
        let before = try read(subject)
        XCTAssertEqual(try XCTUnwrap(before.todayCredits?.estimatedCredits), 59.4002, accuracy: 1e-12)
        func document() throws -> LocalUsageCacheDocument {
            try JSONDecoder().decode(LocalUsageCacheDocument.self, from: Data(contentsOf: root.appendingPathComponent("incremental.json")))
        }
        let previous = try document()
        XCTAssertEqual(previous.cache.weeklyCostObservation?.history?.samples.count, 2)
        // Model signatures and the global calculation revision must both upgrade.
        let cacheURL = root.appendingPathComponent("incremental.json")
        let cacheText = try String(contentsOf: cacheURL, encoding: .utf8)
        try cacheText.replacingOccurrences(of: "pricing-v4|", with: "pricing-v3|").write(to: cacheURL, atomically: true, encoding: .utf8)
        pricing = PricingCatalog.builtin
        subject = scanner("incremental")
        try assertEquivalent(subject, reference, total: 472_001, stage: "new policy after restart")
        let after = try read(subject)
        XCTAssertEqual(after.todayCredits?.estimatedCredits, 5)
        XCTAssertEqual(after.todayCredits?.unpricedTokens, 372_001)
        XCTAssertEqual(try XCTUnwrap(after.todayCost?.estimatedCostUSD), 2.626008, accuracy: 1e-12)
        XCTAssertEqual(after.todayCost?.estimatedCostUSD, before.todayCost?.estimatedCostUSD)
        XCTAssertEqual(Set(after.unpricedUsage?.map(\.reason) ?? []), ["unverifiedCacheWrite", "unsupportedContext"])
        XCTAssertEqual(after.weeklyQuotaCost?.accountScopeKey, before.weeklyQuotaCost?.accountScopeKey)
        XCTAssertEqual(after.weeklyQuotaCost?.baselineUsedPercent, before.weeklyQuotaCost?.baselineUsedPercent)
        XCTAssertEqual(after.weeklyQuotaCost?.observationStartIso, before.weeklyQuotaCost?.observationStartIso)
        let updated = try document()
        XCTAssertEqual(updated.version, 4)
        XCTAssertEqual(updated.cache.weeklyCostObservation?.history?.samples, previous.cache.weeklyCostObservation?.history?.samples)
        let minutes = updated.cache.files.values.flatMap { Array(($0.weeklyTimeline ?? [:]).values) }
        XCTAssertEqual(minutes.reduce(Int64(0)) { $0 + $1.uncertainCreditTokens }, 372_001)
        XCTAssertEqual(minutes.reduce(Int64(0)) { $0 + $1.unpricedTokens }, 0)
        XCTAssertEqual(minutes.reduce(0) { $0 + $1.costUSD }, 2.626008, accuracy: 1e-12)
        let unchanged = try Data(contentsOf: cacheURL)
        _ = try read(subject)
        XCTAssertEqual(try Data(contentsOf: cacheURL), unchanged, "Uncertainty must not repeatedly replay/save unchanged logs")
        pricing = legacy
        try assertEquivalent(subject, reference, total: 472_001, stage: "legacy card rollback")
        XCTAssertEqual(try XCTUnwrap(read(subject).todayCredits?.estimatedCredits), 59.4002, accuracy: 1e-12)
        pricing = PricingCatalog.builtin
        try assertEquivalent(subject, reference, total: 472_001, stage: "upgrade again")
        XCTAssertEqual(try read(subject).todayCredits?.estimatedCredits, 5)
    }

    func testGPT61AndSpeedRateMigrationPreservesWeeklyEvidenceAcrossRestartAndRollback() throws {
        now = ISO8601DateFormatter().date(from: "2026-09-11T04:00:00Z")!
        var oldDocument = PricingCatalog.builtin.document
        oldDocument.api.models.removeValue(forKey: "gpt-6.1-sol")
        oldDocument.credits.models.removeValue(forKey: "gpt-6.1-sol")
        oldDocument.credits.models["gpt-6-astra"]?.serviceTiers?.removeValue(forKey: "ultrafast")
        for model in ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"] {
            oldDocument.credits.models[model]?.serviceTiers?["fast"] = 2.5
            oldDocument.credits.models[model]?.serviceTiers?["priority"] = 2.5
        }
        oldDocument.api.version = "2026-09-23.1"
        oldDocument.credits.version = "2026-09-23.1"
        let oldPricing = PricingCatalog.snapshot(oldDocument, source: "custom", path: nil, error: nil)
        pricing = oldPricing
        var subject = scanner("incremental")
        let reference = scanner("reference")
        try assertEquivalent(subject, reference, total: 0, stage: "old card baseline")
        now.addTimeInterval(60)
        func sample(_ count: Int) -> [String: Any] {
            ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: now),
             "payload": ["type": "token_count", "info": [
                "total_token_usage": ["input_tokens": 100_000 * count, "cached_input_tokens": 80_000 * count,
                                      "output_tokens": 5_000 * count, "total_tokens": 105_000 * count],
                "last_token_usage": ["input_tokens": 100_000]]]]
        }
        for (model, tier) in [("gpt-6.1-sol", "standard"), ("gpt-6-sol", "fast"), ("gpt-6-astra", "ultrafast")] {
            try write([meta(model), ["type": "turn_context", "payload": ["model": model, "service_tier": tier]], sample(1)],
                      to: sessions.appendingPathComponent("\(model).jsonl"))
        }
        try assertEquivalent(subject, reference, total: 315_000, stage: "old card usage")
        let before = try read(subject)
        XCTAssertEqual(try XCTUnwrap(before.todayCost?.estimatedCostUSD), 0.636, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(before.todayCredits?.estimatedCredits), 6.625, accuracy: 1e-12)
        XCTAssertEqual(before.todayCost?.unpricedTokens, 105_000)
        XCTAssertEqual(before.todayCredits?.unpricedTokens, 210_000)
        func document() throws -> LocalUsageCacheDocument {
            try JSONDecoder().decode(LocalUsageCacheDocument.self, from: Data(contentsOf: root.appendingPathComponent("incremental.json")))
        }
        let oldCache = try document()
        XCTAssertEqual(oldCache.cache.weeklyCostObservation?.history?.samples.count, 2)

        pricing = PricingCatalog.builtin
        subject = scanner("incremental")
        try assertEquivalent(subject, reference, total: 315_000, stage: "new card after restart")
        let after = try read(subject)
        XCTAssertEqual(try XCTUnwrap(after.todayCost?.estimatedCostUSD), 0.734, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(after.todayCredits?.estimatedCredits), 87.25, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(after.weeklyQuotaCost?.observedCostUSD), 0.734, accuracy: 1e-12)
        XCTAssertTrue(after.unpricedUsage?.isEmpty == true)
        XCTAssertEqual(after.weeklyQuotaCost?.accountScopeKey, before.weeklyQuotaCost?.accountScopeKey)
        XCTAssertEqual(after.weeklyQuotaCost?.observationStartIso, before.weeklyQuotaCost?.observationStartIso)
        XCTAssertEqual(after.weeklyQuotaCost?.baselineUsedPercent, before.weeklyQuotaCost?.baselineUsedPercent)
        let newCache = try document()
        XCTAssertEqual(newCache.version, 4)
        XCTAssertEqual(newCache.cache.weeklyCostObservation?.history?.samples, oldCache.cache.weeklyCostObservation?.history?.samples)
        let minutes = newCache.cache.files.values.flatMap { Array(($0.weeklyTimeline ?? [:]).values) }
        XCTAssertEqual(minutes.reduce(0) { $0 + $1.costUSD }, 0.734, accuracy: 1e-12)
        XCTAssertEqual(minutes.reduce(Int64(0)) { $0 + $1.uncertainCreditTokens }, 0)
        XCTAssertEqual(minutes.reduce(Int64(0)) { $0 + $1.unpricedTokens }, 0)

        // No new mode event: the persisted Ultrafast cursor must price the append.
        now.addTimeInterval(60)
        try write([sample(2)], to: sessions.appendingPathComponent("gpt-6-astra.jsonl"), append: true)
        subject = scanner("incremental")
        try assertEquivalent(subject, reference, total: 420_000, stage: "append after migration")
        XCTAssertEqual(try XCTUnwrap(read(subject).todayCredits?.estimatedCredits), 166.75, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(read(subject).todayCost?.estimatedCostUSD), 1.264, accuracy: 1e-12)
        pricing = oldPricing
        try assertEquivalent(subject, reference, total: 420_000, stage: "rollback")
        XCTAssertEqual(try read(subject).todayCredits?.unpricedTokens, 315_000)
        pricing = PricingCatalog.builtin
        try assertEquivalent(subject, reference, total: 420_000, stage: "upgrade again")
        XCTAssertEqual(try XCTUnwrap(read(subject).todayCredits?.estimatedCredits), 166.75, accuracy: 1e-12)
    }

    private func legacyCacheWritePricing() -> PricingSnapshot {
        var document = PricingCatalog.builtin.document
        document.api.version = "2026-10-06.1"
        document.api.models["gpt-5.5"]?.cacheWriteInput = 6.25
        document.api.models["gpt-5.4"]?.cacheWriteInput = 3.125
        return PricingCatalog.snapshot(document, source: "custom", path: nil, error: nil)
    }

    private func cacheWriteSample(_ count: Int) -> [String: Any] {
        ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: now),
         "payload": ["type": "token_count", "info": [
            "total_token_usage": ["input_tokens": 100_000 * count, "cached_input_tokens": 40_000 * count,
                "cache_write_input_tokens": 20_000 * count, "output_tokens": 5_000 * count,
                "reasoning_output_tokens": 4_000 * count, "total_tokens": 105_000 * count],
            "last_token_usage": ["input_tokens": 100_000]]]]
    }

    func testLegacyCacheWriteRepricingPreservesWeeklyEvidenceAcrossAppendRestartAndRollback() throws {
        now = ISO8601DateFormatter().date(from: "2026-09-11T04:00:00Z")!
        let legacy = legacyCacheWritePricing()
        pricing = legacy
        var subject = scanner("incremental")
        let reference = scanner("reference")
        try assertEquivalent(subject, reference, total: 0, stage: "write policy baseline")
        now.addTimeInterval(60)
        for name in ["gpt-5.5", "gpt-5.4"] {
            try write([meta(name), model(name), cacheWriteSample(1)], to: sessions.appendingPathComponent("\(name).jsonl"))
        }
        // Unaffected, known-price usage keeps independent credit amounts visible.
        try write([meta("known"), model("gpt-6.1-sol"), token(100_000, delta: 100_000)],
            to: sessions.appendingPathComponent("known.jsonl"))
        try assertEquivalent(subject, reference, total: 310_000, stage: "old write premium")
        XCTAssertEqual(try XCTUnwrap(read(subject).todayCost?.estimatedCostUSD), 0.9425, accuracy: 1e-12)
        let cacheURL = root.appendingPathComponent("incremental.json")
        func document() throws -> LocalUsageCacheDocument {
            try JSONDecoder().decode(LocalUsageCacheDocument.self, from: Data(contentsOf: cacheURL))
        }
        let before = try document()
        XCTAssertEqual(before.cache.weeklyCostObservation?.history?.samples.count, 2)

        pricing = PricingCatalog.builtin
        subject = scanner("incremental")
        try assertEquivalent(subject, reference, total: 310_000, stage: "corrected write rates")
        let after = try read(subject)
        XCTAssertEqual(try XCTUnwrap(after.todayCost?.estimatedCostUSD), 0.905, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(after.weeklyQuotaCost?.observedCostUSD), 0.905, accuracy: 1e-12)
        XCTAssertEqual(after.todayCredits?.estimatedCredits, 5)
        XCTAssertEqual(after.todayCredits?.unpricedTokens, 210_000)
        XCTAssertEqual(after.todayCost?.unpricedTokens, 0)
        XCTAssertEqual(Set(after.unpricedUsage?.map(\.reason) ?? []), ["unverifiedCacheWrite"])
        let updated = try document()
        XCTAssertEqual(updated.version, 4)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(updated.cache.weeklyCostObservation),
                       try encoder.encode(before.cache.weeklyCostObservation))
        let minutes = updated.cache.files.values.flatMap { Array(($0.weeklyTimeline ?? [:]).values) }
        XCTAssertEqual(minutes.reduce(0) { $0 + $1.costUSD }, 0.905, accuracy: 1e-12)
        XCTAssertEqual(minutes.reduce(Int64(0)) { $0 + $1.uncertainCreditTokens }, 210_000)
        for name in pricing.document.api.models.keys {
            let oldSignature = PricingCatalog.$current.withValue(legacy) { TokenCostEstimator.pricingSignature(for: name) }
            let newSignature = PricingCatalog.$current.withValue(pricing) { TokenCostEstimator.pricingSignature(for: name) }
            if ["gpt-5.5", "gpt-5.4"].contains(name) { XCTAssertNotEqual(oldSignature, newSignature, name) }
            else { XCTAssertEqual(oldSignature, newSignature, name) }
        }
        let unchanged = try Data(contentsOf: cacheURL)
        _ = try read(scanner("incremental"))
        XCTAssertEqual(try Data(contentsOf: cacheURL), unchanged)

        now.addTimeInterval(60)
        try write([cacheWriteSample(2)], to: sessions.appendingPathComponent("gpt-5.5.jsonl"), append: true)
        try assertEquivalent(subject, reference, total: 415_000, stage: "write append")
        XCTAssertEqual(try XCTUnwrap(read(subject).todayCost?.estimatedCostUSD), 1.375, accuracy: 1e-12)
        let history = try document().cache.weeklyCostObservation?.history?.samples
        for (card, expected, stage) in [(legacy, 1.4375, "write rollback"), (PricingCatalog.builtin, 1.375, "write upgrade again")] {
            pricing = card
            subject = scanner("incremental")
            try assertEquivalent(subject, reference, total: 415_000, stage: stage)
            XCTAssertEqual(try XCTUnwrap(read(subject).todayCost?.estimatedCostUSD), expected, accuracy: 1e-12)
            XCTAssertEqual(try document().cache.weeklyCostObservation?.history?.samples, history)
        }
    }

    func testLegacyCacheWriteRepricingKeepsMissingLogsStaleUntilRestored() throws {
        now = ISO8601DateFormatter().date(from: "2026-09-11T04:00:00Z")!
        pricing = legacyCacheWritePricing()
        let subject = scanner("incremental")
        _ = try read(subject)
        now.addTimeInterval(60)
        let file = sessions.appendingPathComponent("missing-writes.jsonl")
        try write([meta("writes"), model("gpt-5.5"), cacheWriteSample(1)], to: file)
        XCTAssertEqual(try XCTUnwrap(read(subject).todayCost?.estimatedCostUSD), 0.495, accuracy: 1e-12)
        let saved = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        pricing = PricingCatalog.builtin
        for value in [subject, scanner("incremental")] {
            let missing = try read(value)
            XCTAssertEqual(missing.totalTokens, 105_000)
            XCTAssertNil(missing.todayCost?.estimatedCostUSD)
            XCTAssertEqual(missing.todayCost?.unpricedTokens, 105_000)
            XCTAssertEqual(missing.unpricedUsage?.first { $0.kind == "api" }?.reason, "stalePricing")
        }
        try saved.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let restored = try read(scanner("incremental"))
        XCTAssertEqual(restored.totalTokens, 105_000)
        XCTAssertEqual(try XCTUnwrap(restored.todayCost?.estimatedCostUSD), 0.47, accuracy: 1e-12)
        XCTAssertEqual(restored.todayCost?.unpricedTokens, 0)
        XCTAssertEqual(restored.todayCredits?.unpricedTokens, 105_000)
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
