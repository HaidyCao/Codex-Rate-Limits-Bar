import Foundation
import XCTest
@testable import CodexRateLimitsCore

final class AutoReviewBillingTests: XCTestCase {
    private var root: URL!
    private var now = ISO8601DateFormatter().date(from: "2026-10-07T10:00:00Z")!
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AutoReviewBilling-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func scanner() -> LocalUsageScanner {
        LocalUsageScanner(rootURLs: [root], calendar: calendar, now: { self.now },
                          cacheFileURL: root.appendingPathComponent("cache.json"))
    }
    private func meta(_ id: String, guardian: Bool = true, provider: String = "openai") -> [String: Any] {
        ["type": "session_meta", "payload": ["id": id, "model_provider": provider,
            "source": guardian ? ["subagent": ["other": "guardian"]] as Any : "cli"]]
    }
    private func token(_ total: Int, model: String = "codex-auto-review", signedIn: Bool = true) -> [String: Any] {
        var payload: [String: Any] = ["type": "token_count", "info": ["model": model, "service_tier": "standard",
            "total_token_usage": ["input_tokens": total, "total_tokens": total],
            "last_token_usage": ["input_tokens": 100]]]
        if signedIn {
            // Current reviewer logs can omit plan_type. The quota is recorded
            // on this call; the home's current credentials are irrelevant.
            payload["rate_limits"] = ["limit_id": "codex", "plan_type": NSNull(),
                "primary": ["used_percent": 20, "window_minutes": 300, "resets_at": 1_900_000_000]]
        }
        return ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: now), "payload": payload]
    }
    private func write(_ rows: [[String: Any]], to name: String, append: Bool = false) throws {
        let url = root.appendingPathComponent(name)
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); data.append(10) }
        if append {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        } else { try data.write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    }

    func testRecordedChatGPTSafetyChecksAreFreeWithoutInventingAnAPIPrice() throws {
        try write([meta("review"), token(300)], to: "review.jsonl")
        let reader = scanner()
        for value in [try reader.snapshot(), try reader.snapshot(), try scanner().snapshot(), try reader.snapshot(rebuild: true)] {
            XCTAssertEqual(value.totalTokens, 300)
            XCTAssertNil(value.todayCost?.estimatedCostUSD, "An exemption does not establish an API equivalent")
            XCTAssertEqual(value.todayCost?.unpricedTokens, 0)
            XCTAssertEqual(value.todayCredits?.estimatedCredits, 0)
            XCTAssertEqual(value.todayCredits?.pricedTokens, 300)
            XCTAssertEqual(value.todayCredits?.unpricedTokens, 0)
            XCTAssertEqual(value.todayCredits?.coveragePercent, 100)
            XCTAssertEqual(value.todayCost?.notApplicableTokens, 300)
            XCTAssertEqual(value.todayCredits?.exemptTokens, 300)
            XCTAssertEqual(value.autoReviewUsage?.freeTokens, 300)
            XCTAssertEqual(value.autoReviewUsage?.unverifiedTokens, 0)
            XCTAssertTrue(AppText.pricingCoverage(cost: value.todayCost, credits: value.todayCredits).contains("API N/A"))
            XCTAssertTrue(value.unpricedUsage?.isEmpty == true)
        }
        now.addTimeInterval(60)
        try write([token(500)], to: "review.jsonl", append: true)
        XCTAssertEqual(try reader.snapshot().totalTokens, 500)
        XCTAssertEqual(try scanner().snapshot().todayCredits?.estimatedCredits, 0)
    }

    func testReviewNameAloneAndOtherProvidersDoNotEstablishAFreeCall() throws {
        let cases: [(String, Bool, String, Bool, String)] = [
            ("name-only", false, "openai", true, "codex-auto-review"),
            ("no-login-evidence", true, "openai", false, "codex-auto-review"),
            ("api-provider", true, "private", true, "codex-auto-review"),
            ("unknown-variant", true, "openai", true, "codex-auto-review-latest")
        ]
        for (name, guardian, provider, signedIn, model) in cases {
            try write([meta(name, guardian: guardian, provider: provider), token(100, model: model, signedIn: signedIn)], to: name + ".jsonl")
        }
        let value = try scanner().snapshot()
        XCTAssertEqual(value.totalTokens, 400)
        XCTAssertNil(value.todayCredits?.estimatedCredits)
        XCTAssertEqual(value.todayCredits?.unpricedTokens, 400)
        XCTAssertEqual(value.todayCost?.unpricedTokens, 400)
    }

    func testMixedFreeUnknownAndNormalWorkKeepsSeparateCoverageAndRawTotals() throws {
        try write([meta("free"), token(300)], to: "free.jsonl")
        try write([meta("unverified"), token(100, signedIn: false)], to: "unverified.jsonl")
        try write([meta("normal", guardian: false), token(1_000, model: "gpt-6.1-sol")], to: "normal.jsonl")
        let value = try scanner().snapshot()
        XCTAssertEqual(value.totalTokens, 1_400)
        XCTAssertEqual(try XCTUnwrap(value.todayCost?.estimatedCostUSD), 0.002, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(value.todayCredits?.estimatedCredits), 0.05, accuracy: 1e-12)
        XCTAssertEqual(value.todayCost?.pricedTokens, 1_000)
        XCTAssertEqual(value.todayCost?.unpricedTokens, 100)
        XCTAssertEqual(value.todayCredits?.pricedTokens, 1_300)
        XCTAssertEqual(value.todayCredits?.unpricedTokens, 100)
        XCTAssertEqual(try XCTUnwrap(value.todayCost?.coveragePercent), 100_000.0 / 1_100, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(value.todayCredits?.coveragePercent), 130_000.0 / 1_400, accuracy: 1e-10)
        XCTAssertEqual(value.autoReviewUsage?.freeTokens, 300)
        XCTAssertEqual(value.autoReviewUsage?.unverifiedTokens, 100)
        XCTAssertEqual(value.unpricedUsage?.filter { $0.reason == "autoReviewContextUnverified" }.count, 2)
    }

    func testCopiesWithConflictingApprovalSourcesDoNotGainAnExemptionOrDoubleCount() throws {
        let event = token(300)
        try write([meta("copy"), event], to: "a.jsonl")
        try write([meta("copy", guardian: false), event], to: "b.jsonl")
        let reader = scanner()
        for value in [try reader.snapshot(), try scanner().snapshot(), try reader.snapshot(rebuild: true)] {
            XCTAssertEqual(value.totalTokens, 300)
            XCTAssertNil(value.todayCredits?.estimatedCredits)
            XCTAssertEqual(value.todayCredits?.unpricedTokens, 300)
            XCTAssertEqual(value.autoReviewUsage?.unverifiedTokens, 300)
            XCTAssertEqual(value.autoReviewUsage?.freeTokens, 0)
        }
    }

    func testQuotaEvidenceIsCallLocalAndRejectsMalformedWindowsAndCredits() throws {
        let cases: [(String, [String: Any])] = [
            ("credits-only", ["limit_id": "codex", "credits": ["has_credits": false, "unlimited": false]]),
            ("secondary-only", ["limit_id": "codex", "secondary": ["used_percent": 0, "window_minutes": 10080]]),
            ("boolean-window", ["limit_id": "codex", "primary": ["used_percent": true, "window_minutes": 300]]),
            ("oversized-window", ["limit_id": "codex", "primary": ["used_percent": 101, "window_minutes": 300]]),
            ("numeric-credits", ["limit_id": "codex", "credits": ["has_credits": 1, "unlimited": 0]]),
            ("empty-quota", ["limit_id": "codex", "plan_type": "pro"]),
            ("other-quota", ["limit_id": "other", "primary": ["used_percent": 20, "window_minutes": 300]])
        ]
        for (name, limits) in cases {
            var event = token(100, signedIn: false)
            var payload = event["payload"] as! [String: Any]
            payload["rate_limits"] = limits
            event["payload"] = payload
            try write([meta(name), event], to: name + ".jsonl")
        }
        // The valid quota on a previous token event must not exempt a later call.
        try write([meta("changing-auth"), token(100), token(200, signedIn: false)], to: "changing-auth.jsonl")
        let value = try scanner().snapshot()
        XCTAssertEqual(value.totalTokens, 900)
        XCTAssertEqual(value.todayCredits?.exemptTokens, 300)
        XCTAssertEqual(value.todayCost?.notApplicableTokens, 300)
        XCTAssertEqual(value.todayCredits?.unpricedTokens, 600)
        XCTAssertEqual(value.autoReviewUsage?.unverifiedTokens, 600)
    }

    func testFreeChecksRetainIncompleteTokensWithoutInventingBillingAssumptions() throws {
        var event = token(300)
        var payload = event["payload"] as! [String: Any]
        payload["info"] = ["model": "codex-auto-review", "service_tier": "unknown-mode",
                           "total_token_usage": ["total_tokens": 300]]
        event["payload"] = payload
        try write([meta("incomplete"), event], to: "incomplete.jsonl")
        let value = try scanner().snapshot()
        XCTAssertEqual(value.totalTokens, 300)
        XCTAssertEqual(value.todayCredits?.estimatedCredits, 0)
        XCTAssertEqual(value.todayCredits?.exemptTokens, 300)
        XCTAssertEqual(value.todayCost?.notApplicableTokens, 300)
        XCTAssertEqual(value.billingAssumptions?.assumedCreditTokens, 0)
        XCTAssertEqual(value.billingAssumptions?.missingRequestContextTokens, 0)
        XCTAssertTrue(value.unpricedUsage?.isEmpty == true)
        XCTAssertTrue(value.hasIncompleteTokenBreakdown)
    }

    func testSessionRoleChangesClearExemptionAndCachedContextContainsNoIdentity() throws {
        var header = meta("changing-role")
        var payload = header["payload"] as! [String: Any]
        payload["creator_account_id"] = "private-account-canary"
        payload["creator_user_id"] = "private-user-canary"
        header["payload"] = payload
        try write([header, token(300), meta("changing-role", guardian: false), token(500)], to: "roles.jsonl")
        let value = try scanner().snapshot()
        XCTAssertEqual(value.totalTokens, 500)
        XCTAssertEqual(value.autoReviewUsage?.freeTokens, 300)
        XCTAssertEqual(value.todayCredits?.unpricedTokens, 200)
        let cache = try String(contentsOf: root.appendingPathComponent("cache.json"), encoding: .utf8)
        XCTAssertFalse(cache.contains("private-account-canary"))
        XCTAssertFalse(cache.contains("private-user-canary"))
    }

    func testMatchingCopiesCountFreeChecksOnceAcrossAppendRestartAndRebuild() throws {
        let events = [meta("matching-copy"), token(300)]
        for name in ["a.jsonl", "b.jsonl"] { try write(events, to: name) }
        let reader = scanner()
        XCTAssertEqual(try reader.snapshot().autoReviewUsage?.freeTokens, 300)
        now.addTimeInterval(60)
        for name in ["a.jsonl", "b.jsonl"] { try write([token(500)], to: name, append: true) }
        for value in [try reader.snapshot(), try scanner().snapshot(), try reader.snapshot(rebuild: true)] {
            XCTAssertEqual(value.totalTokens, 500)
            XCTAssertEqual(value.autoReviewUsage?.freeTokens, 500)
            XCTAssertEqual(value.todayCost?.notApplicableTokens, 500)
            XCTAssertEqual(value.todayCredits?.estimatedCredits, 0)
        }
    }

    func testInvalidSessionMetadataClearsFreeContextAcrossRestartAndAppend() throws {
        try write([meta("review"), token(300), ["type": "session_meta", "payload": ["source": "cli"]], token(500)], to: "review.jsonl")
        let first = try scanner().snapshot()
        XCTAssertEqual(first.autoReviewUsage?.freeTokens, 300)
        XCTAssertEqual(first.todayCredits?.unpricedTokens, 200)
        now.addTimeInterval(60)
        try write([token(800)], to: "review.jsonl", append: true)
        let appended = try scanner().snapshot()
        XCTAssertEqual(appended.autoReviewUsage?.freeTokens, 300)
        XCTAssertEqual(appended.todayCredits?.unpricedTokens, 500)
    }

    func testNewOptionalFieldsAreAbsentFromOrdinaryUsageAndOldSnapshotsStillDecode() throws {
        try write([meta("normal", guardian: false), token(1_000, model: "gpt-6.1-sol")], to: "normal.jsonl")
        let value = try scanner().snapshot()
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(object["autoReviewUsage"])
        XCTAssertNil(object["tokenBreakdownUnavailable"])
        XCTAssertNil((object["todayCost"] as? [String: Any])?["notApplicableTokens"])
        XCTAssertNil((object["todayCredits"] as? [String: Any])?["exemptTokens"])
        let decoded = try JSONDecoder().decode(LocalUsageSnapshot.self, from: data)
        XCTAssertEqual(decoded.totalTokens, 1_000)
        XCTAssertNil(decoded.autoReviewUsage)
        XCTAssertNil(decoded.todayCost?.notApplicableTokens)
        XCTAssertNil(decoded.todayCredits?.exemptTokens)
    }

    func testExplicitCustomPricesStillApplyToUnverifiedAndOrdinaryWork() throws {
        var document = PricingCatalog.builtin.document
        document.api.models["codex-auto-review"] = document.api.models["gpt-6.1-sol"]
        document.credits.models["codex-auto-review"] = document.credits.models["gpt-6.1-sol"]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(document)
        let validated = try PricingCatalog.decode(original)
        let pricing = PricingCatalog.snapshot(validated, source: "custom", path: nil, error: nil)
        try write([meta("free"), token(300)], to: "free.jsonl")
        try write([meta("unverified"), token(1_000, signedIn: false)], to: "unverified.jsonl")
        try write([meta("ordinary", guardian: false), token(1_000)], to: "ordinary.jsonl")
        let reader = LocalUsageScanner(rootURLs: [root], calendar: calendar, now: { self.now }, pricingProvider: { pricing })
        let value = try reader.snapshot()
        XCTAssertEqual(value.totalTokens, 2_300)
        XCTAssertEqual(try XCTUnwrap(value.todayCost?.estimatedCostUSD), 0.004, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(value.todayCredits?.estimatedCredits), 0.1, accuracy: 1e-12)
        XCTAssertEqual(value.todayCredits?.exemptTokens, 300)
        XCTAssertEqual(value.todayCost?.notApplicableTokens, 300)
        XCTAssertEqual(value.autoReviewUsage?.unverifiedTokens, 1_000)
        XCTAssertEqual(try encoder.encode(document), original)
    }

    private func editCache(_ edit: (inout [String: Any]) -> Void) throws {
        let url = root.appendingPathComponent("cache.json")
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        edit(&document)
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: url, options: .atomic)
    }

    private func removePolicy(from value: Any) -> Any {
        guard var object = value as? [String: Any] else {
            if let array = value as? [Any] { return array.map(removePolicy) }
            return value
        }
        object = object.mapValues(removePolicy)
        object.removeValue(forKey: "sessionBillingContext")
        object.removeValue(forKey: "exemptTokens")
        if let signature = object["pricingSignature"] as? String, signature.hasSuffix("|chatgpt-auto-review-v1") {
            object["pricingSignature"] = String(signature.dropLast("|chatgpt-auto-review-v1".count))
            let total = (object["usage"] as! [String: Any])["totalTokens"] as! Int
            for key in ["api", "credits"] {
                var totals = object[key] as! [String: Any]
                totals["pricedTokens"] = 0; totals["unpricedTokens"] = total
                totals.removeValue(forKey: "notApplicableTokens")
                object[key] = totals
            }
            object["missing"] = ["api", "credits"].map { ["kind": $0, "tier": "standard", "reason": "unknownModel", "tokens": total] }
        }
        return object
    }

    private var window: RateLimitWindow {
        RateLimitWindow(usedPercent: 10, remainingPercent: 90, windowDurationMins: 10080,
                        resetsAt: Int(now.addingTimeInterval(3 * 86400).timeIntervalSince1970), resetsAtIso: nil)
    }

    func testVersionFourCacheReplaysOnlyAffectedModelAndPreservesObservation() throws {
        try write([meta("review")], to: "review.jsonl")
        try write([meta("normal", guardian: false)], to: "normal.jsonl")
        let reader = scanner(), quota = window
        let baseline = try reader.snapshot(weeklyWindow: quota, quotaSampleAt: now)
        now.addTimeInterval(60)
        try write([token(300)], to: "review.jsonl", append: true)
        try write([token(1_000, model: "gpt-6.1-sol")], to: "normal.jsonl", append: true)
        _ = try reader.snapshot(weeklyWindow: quota, quotaSampleAt: now)
        var observation: NSDictionary!
        try editCache { document in
            document = removePolicy(from: document) as! [String: Any]
            var cache = document["cache"] as! [String: Any]
            observation = cache["weeklyCostObservation"] as? NSDictionary
            var files = cache["files"] as! [String: [String: Any]]
            for path in files.keys {
                var diagnostics = files[path]?["diagnostics"] as! [String: Any]
                diagnostics.removeValue(forKey: "blankLinesChecked")
                files[path]?["diagnostics"] = diagnostics
            }
            cache["files"] = files; document["cache"] = cache
        }
        let migrated = try scanner().snapshot(weeklyWindow: quota, quotaSampleAt: now)
        XCTAssertEqual(migrated.autoReviewUsage?.freeTokens, 300)
        XCTAssertEqual(migrated.weeklyQuotaCost?.autoReviewUsage?.freeTokens, 300)
        XCTAssertEqual(migrated.weeklyQuotaCost?.observationStartIso, baseline.weeklyQuotaCost?.observationStartIso)
        XCTAssertEqual(migrated.weeklyQuotaCost?.baselineUsedPercent, 10)
        let url = root.appendingPathComponent("cache.json")
        let data = try Data(contentsOf: url)
        let document = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(document["version"] as? Int, 4)
        let cache = document["cache"] as! [String: Any]
        XCTAssertEqual(cache["weeklyCostObservation"] as? NSDictionary, observation)
        let files = cache["files"] as! [String: [String: Any]]
        XCTAssertNil((files[root.appendingPathComponent("normal.jsonl").path]?["diagnostics"] as? [String: Any])?["blankLinesChecked"])
        XCTAssertEqual((files[root.appendingPathComponent("review.jsonl").path]?["diagnostics"] as? [String: Any])?["blankLinesChecked"] as? Bool, true)
        _ = try scanner().snapshot(weeklyWindow: quota, quotaSampleAt: now)
        XCTAssertEqual(try Data(contentsOf: url), data, "Migration must not replay/write unchanged logs again")
    }

    func testMissingLegacyReviewLogDoesNotInventAnExemption() throws {
        try write([meta("review"), token(300)], to: "review.jsonl")
        _ = try scanner().snapshot()
        try editCache { $0 = removePolicy(from: $0) as! [String: Any] }
        try FileManager.default.removeItem(at: root.appendingPathComponent("review.jsonl"))
        let value = try scanner().snapshot()
        XCTAssertEqual(value.totalTokens, 300)
        XCTAssertNil(value.autoReviewUsage)
        XCTAssertNil(value.todayCredits?.estimatedCredits)
        XCTAssertEqual(value.todayCredits?.unpricedTokens, 300)
        XCTAssertEqual(value.unpricedUsage?.first?.reason, "stalePricing")
    }

    func testOldOrdinaryCopiesReuseTheirCacheWhileReviewCopiesReplay() throws {
        for name in ["normal-a.jsonl", "normal-b.jsonl"] {
            try write([meta("normal", guardian: false), token(1_000, model: "gpt-6.1-sol")], to: name)
        }
        for name in ["review-a.jsonl", "review-b.jsonl"] { try write([meta("review"), token(300)], to: name) }
        _ = try scanner().snapshot()
        try editCache { document in
            document = removePolicy(from: document) as! [String: Any]
            var cache = document["cache"] as! [String: Any]
            var files = cache["files"] as! [String: [String: Any]]
            for path in files.keys {
                files[path]?["copyAlgorithmVersion"] = 1
                var diagnostics = files[path]?["diagnostics"] as! [String: Any]
                diagnostics.removeValue(forKey: "blankLinesChecked")
                files[path]?["diagnostics"] = diagnostics
            }
            cache["files"] = files; document["cache"] = cache
        }
        let value = try scanner().snapshot()
        XCTAssertEqual(value.totalTokens, 1_300)
        XCTAssertEqual(value.autoReviewUsage?.freeTokens, 300)
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("cache.json"))) as! [String: Any]
        let cache = document["cache"] as! [String: Any], files = cache["files"] as! [String: [String: Any]]
        for (path, state) in files {
            if path.contains("normal-") {
                XCTAssertNil((state["diagnostics"] as? [String: Any])?["blankLinesChecked"])
                XCTAssertEqual(state["copyAlgorithmVersion"] as? Int, 1)
            } else {
                XCTAssertEqual(state["copyAlgorithmVersion"] as? Int, UsageCopyLedger.currentVersion)
            }
        }
    }

    func testLegacyAppendRecoversHeaderSourceWithoutReplayingNormalHistory() throws {
        try write([meta("review"), token(1_000, model: "gpt-6.1-sol")], to: "review.jsonl")
        _ = try scanner().snapshot()
        try editCache { $0 = removePolicy(from: $0) as! [String: Any] }
        now.addTimeInterval(60)
        try write([token(1_300)], to: "review.jsonl", append: true)
        let value = try scanner().snapshot()
        XCTAssertEqual(value.totalTokens, 1_300)
        XCTAssertEqual(value.autoReviewUsage?.freeTokens, 300)
        XCTAssertEqual(try XCTUnwrap(value.todayCost?.estimatedCostUSD), 0.002, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(value.todayCredits?.estimatedCredits), 0.05, accuracy: 1e-12)
    }

    func testWeeklyExemptionsFollowActiveHomeAndDoNotAddQuotaCosts() throws {
        let active = root.appendingPathComponent("active"), other = root.appendingPathComponent("other")
        for folder in [active, other] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try write([meta("active")], to: "active/review.jsonl")
        try write([meta("other"), token(300)], to: "other/review.jsonl")
        func reader() -> LocalUsageScanner {
            LocalUsageScanner(rootURLs: [active, other], calendar: calendar, now: { self.now },
                              cacheFileURL: root.appendingPathComponent("cache.json"), weeklyRootURLs: [active])
        }
        let scanner = reader(), quota = window
        let baseline = try scanner.snapshot(weeklyWindow: quota, quotaSampleAt: now)
        now.addTimeInterval(60)
        try write([token(200)], to: "active/review.jsonl", append: true)
        try write([meta("normal", guardian: false), token(1_000, model: "gpt-6.1-sol")], to: "active/normal.jsonl")
        for value in [try scanner.snapshot(weeklyWindow: quota, quotaSampleAt: now),
                      try reader().snapshot(weeklyWindow: quota, quotaSampleAt: now),
                      try scanner.snapshot(weeklyWindow: quota, rebuild: true, quotaSampleAt: now)] {
            XCTAssertEqual(value.totalTokens, 1_500)
            XCTAssertEqual(value.autoReviewUsage?.freeTokens, 500)
            XCTAssertEqual(value.weeklyQuotaCost?.autoReviewUsage?.freeTokens, 200)
            XCTAssertEqual(value.weeklyQuotaCost?.notApplicableTokens, 200)
            XCTAssertEqual(value.weeklyQuotaCost?.unpricedTokens, 0)
            XCTAssertEqual(try XCTUnwrap(value.weeklyQuotaCost?.observedCostUSD), 0.002, accuracy: 1e-12)
            XCTAssertEqual(value.weeklyQuotaCost?.observationStartIso, baseline.weeklyQuotaCost?.observationStartIso)
        }
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("cache.json"))) as! [String: Any]
        let cache = document["cache"] as! [String: Any], files = cache["files"] as! [String: [String: Any]]
        let timeline = files[active.appendingPathComponent("review.jsonl").path]?["weeklyTimeline"] as! [String: [String: Any]]
        XCTAssertEqual(timeline.values.reduce(0) { $0 + ($1["exemptTokens"] as? Int ?? 0) }, 200)
        XCTAssertTrue(timeline.values.allSatisfy { ($0["costUSD"] as? Double) == 0 && ($0["unpricedTokens"] as? Int) == 0 })
    }
}
