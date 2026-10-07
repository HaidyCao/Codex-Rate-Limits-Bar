import Foundation
import XCTest
@testable import CodexRateLimitsCore

final class ClientContractTests: XCTestCase {
    private var root: URL!
    private let now = ISO8601DateFormatter().date(from: "2026-10-06T13:00:00Z")!
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/client-contracts")
    }
    private var sessions: URL { root.appendingPathComponent("sessions") }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ClientContracts-\(UUID())")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func document(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent(name + ".json"))) as? [String: Any])
    }
    private func scanner(_ cache: String) -> LocalUsageScanner {
        LocalUsageScanner(rootURLs: [sessions], calendar: calendar, now: { self.now },
                          cacheFileURL: root.appendingPathComponent(cache + ".json"))
    }
    private func write(_ events: [[String: Any]], name: String, append: Bool = false) throws {
        var data = Data()
        for event in events {
            data.append(try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]))
            data.append(10)
        }
        let url = sessions.appendingPathComponent(name + ".jsonl")
        if append {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else { try data.write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    }
    private func assertAmounts(_ value: LocalUsageSnapshot, tokens: Int64, api: Double, credits: Double,
                               missingTier: Int64, apiUnpriced: Int64 = 0, creditUnpriced: Int64 = 0,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(value.totalTokens, tokens, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(value.todayCost?.estimatedCostUSD), api, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(value.todayCredits?.estimatedCredits), credits, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(value.todayCost?.unpricedTokens, apiUnpriced, file: file, line: line)
        XCTAssertEqual(value.todayCredits?.unpricedTokens, creditUnpriced, file: file, line: line)
        XCTAssertEqual(value.billingAssumptions?.missingServiceTierTokens, missingTier, file: file, line: line)
        XCTAssertEqual(value.billingAssumptions?.missingRequestContextTokens, 0, file: file, line: line)
        XCTAssertEqual(value.diagnostics?.status, .complete, file: file, line: line)
    }

    func testObservedClientCountersAndParentChildCopiesSurviveIncrementalRestartAndRebuild() throws {
        let files = try XCTUnwrap(document("observed-rollouts")["files"] as? [[String: Any]])
        let subject = scanner("incremental")
        for file in files {
            let name = try XCTUnwrap(file["name"] as? String)
            let events = try XCTUnwrap(file["events"] as? [[String: Any]])
            for suffix in ["", "-copy"] { try write(Array(events.dropLast()), name: name + suffix) }
        }
        XCTAssertEqual(try subject.snapshot().totalTokens, 102_644)
        for file in files {
            let name = file["name"] as! String
            let events = file["events"] as! [[String: Any]]
            for suffix in ["", "-copy"] { try write([events.last!], name: name + suffix, append: true) }
        }
        for value in [try subject.snapshot(), try scanner("incremental").snapshot(), try scanner("rebuilt").snapshot(rebuild: true)] {
            try assertAmounts(value, tokens: 245_087, api: 0.30183598, credits: 7.5458995, missingTier: 245_087)
            XCTAssertEqual(value.todayCredits?.coveragePercent, 100)
            XCTAssertEqual(value.billingAssumptions?.creditPercent, 100)
            XCTAssertEqual(value.billingAssumptions?.apiPercent, 0)
            XCTAssertEqual(value.topFiles?.count, 5)
            XCTAssertTrue(value.topFiles?.allSatisfy { $0.sourceFiles?.count == 2 } == true)
            XCTAssertTrue(value.unpricedUsage?.isEmpty == true)
        }
        let child = try XCTUnwrap(files.first { $0["name"] as? String == "child-observed" })
        let payload = (child["events"] as! [[String: Any]])[0]["payload"] as! [String: Any]
        let source = payload["source"] as! [String: Any]
        let spawn = (source["subagent"] as! [String: Any])["thread_spawn"] as! [String: Any]
        XCTAssertEqual(spawn["parent_thread_id"] as? String, "parent-observed")
        XCTAssertNotEqual(payload["id"] as? String, spawn["parent_thread_id"] as? String)
    }

    func testSyntheticSpeedAndModelChangesKeepIndependentUnknownReasonsAcrossRestart() throws {
        let files = try XCTUnwrap(document("synthetic-modes")["files"] as? [[String: Any]])
        let subject = scanner("incremental")
        for file in files {
            let name = file["name"] as! String, events = file["events"] as! [[String: Any]]
            for suffix in ["", "-copy"] { try write(Array(events.dropLast()), name: name + suffix) }
        }
        try assertAmounts(subject.snapshot(), tokens: 525_000, api: 0.8293, credits: 87.115,
                          missingTier: 105_000, creditUnpriced: 105_000)
        for file in files {
            let name = file["name"] as! String, events = file["events"] as! [[String: Any]]
            for suffix in ["", "-copy"] { try write([events.last!], name: name + suffix, append: true) }
        }
        for value in [try subject.snapshot(), try scanner("incremental").snapshot(), try scanner("rebuilt").snapshot(rebuild: true)] {
            try assertAmounts(value, tokens: 735_000, api: 0.9353, credits: 92.415,
                              missingTier: 105_000, apiUnpriced: 105_000, creditUnpriced: 210_000)
            XCTAssertEqual(value.unpricedUsage?.map { "\($0.kind):\($0.model):\($0.reason)" }.sorted(), [
                "api:fixture-unpriced:unknownModel", "credits:fixture-unpriced:unknownModel",
                "credits:gpt-6.1-sol:unknownServiceTier"
            ])
            XCTAssertEqual(value.topFiles?.count, 2)
            XCTAssertTrue(value.topFiles?.allSatisfy { $0.sourceFiles?.count == 2 } == true)
        }
    }

    func testRecordedTierPrecedenceDoesNotInventAnActualBillingTier() throws {
        let usage: [String: Any] = ["input_tokens": 100_000, "cached_input_tokens": 80_000,
                                    "output_tokens": 5_000, "total_tokens": 105_000]
        // info > token payload > current turn context. These legacy fields are
        // recorded settings, not a verified actual-service-tier protocol.
        for (name, infoTier, payloadTier, expected) in [
            ("info-wins", "standard", "fast", 2.45),
            ("payload-wins", nil, "fast", 4.9),
            ("context-fallback", nil, nil, 2.45)
        ] as [(String, String?, String?, Double)] {
            var info: [String: Any] = ["total_token_usage": usage, "last_token_usage": usage]
            info["service_tier"] = infoTier
            var payload: [String: Any] = ["type": "token_count", "info": info]
            payload["serviceTier"] = payloadTier
            try write([
                ["type": "session_meta", "payload": ["id": name]],
                ["type": "turn_context", "payload": ["model": "gpt-6.1-sol", "service_tier": "standard"]],
                ["type": "event_msg", "timestamp": "2026-10-06T12:00:00Z", "payload": payload]
            ], name: name)
            let value = try scanner(name).snapshot(rebuild: true)
            let model = try XCTUnwrap(value.todayCredits?.models.first { $0.model == "gpt-6.1-sol" })
            XCTAssertEqual(try XCTUnwrap(model.estimatedCredits), expected, accuracy: 1e-12)
            try FileManager.default.removeItem(at: sessions.appendingPathComponent(name + ".jsonl"))
        }
        // No guessed requested/actual keys are accepted as billing evidence.
        XCTAssertNil(LocalUsageLog.serviceTierFromPayload(["requested_service_tier": "fast", "actual_service_tier": "standard"]))
        let evidence = try XCTUnwrap(document("protocol-evidence")["schemas"] as? [String: Any])
        let notification = evidence["ThreadTokenUsageUpdatedNotification"] as! [String: Any]
        XCTAssertEqual(notification["fields"] as? [String], ["threadId", "tokenUsage", "turnId"])
    }

    func testSparseSettingsPreserveTierButFullTurnWithoutTierClearsIt() throws {
        func token(_ total: Int, _ second: Int) -> [String: Any] {
            ["type": "event_msg", "timestamp": "2026-10-06T12:00:0\(second)Z", "payload": ["type": "token_count", "info": [
                "total_token_usage": ["input_tokens": total, "total_tokens": total], "last_token_usage": ["input_tokens": 1000]]]]
        }
        try write([
            ["type": "session_meta", "payload": ["id": "settings"]],
            ["type": "turn_context", "payload": ["model": "gpt-6.1-sol", "service_tier": "fast"]], token(1000, 1),
            ["type": "event_msg", "payload": ["type": "thread_settings_applied", "model": "gpt-6.1-sol"]], token(2000, 2),
            ["type": "turn_context", "payload": ["model": "gpt-6.1-sol"]], token(3000, 3),
            ["type": "event_msg", "payload": ["type": "thread_settings_applied", "serviceTier": "fast"]], token(4000, 4),
            ["type": "event_msg", "payload": ["type": "thread_settings_applied", "serviceTier": NSNull()]], token(5000, 5)
        ], name: "settings")
        try assertAmounts(scanner("settings").snapshot(), tokens: 5000, api: 0.01, credits: 0.4, missingTier: 2000)
    }

    func testAccountContractsUseReturnedWindowsAndKeepUnavailableSeparateFromZero() throws {
        let cases = try XCTUnwrap(document("official-accounts")["cases"] as? [[String: Any]])
        for fixture in cases {
            let name = fixture["name"] as! String
            let response = fixture["rateLimitsResponse"] as! [String: Any]
            let expected = fixture["expected"] as! [String: Any]
            let source = CodexAccountSource(environment: ["CODEX_HOME": root.path], home: root)
            let client = OfficialUsageClient(sourceProvider: { source }, call: { _, _ in
                ["account/read": fixture["accountResponse"]!, "account/rateLimits/read": response]
            }, fetchReset: { _ in XCTFail("Contract fixture must never request credentials or network"); return Data() })
            let value = try client.readAccountPayload(includeUsage: false)
            let weekly = expected["weeklyRemaining"] as? Int
            let balance = expected["balance"] as? String
            XCTAssertEqual(value.selectedRateLimit?.weeklyWindow?.remainingPercent, weekly, name)
            XCTAssertEqual(value.selectedRateLimit?.credits?.balance, balance, name)
            XCTAssertEqual(value.display?.primaryRemainingPercent, weekly, name)
            XCTAssertEqual(value.refresh?.quota.status, weekly == nil ? .unavailable : .success, name)
            XCTAssertEqual(value.refresh?.credits.status, balance == nil ? .unavailable : .success, name)
            XCTAssertNil(value.accountContext?.scopeKey, "Unverified fixture identity cannot acquire a baseline")
            XCTAssertNil(value.rateLimitError, name)
            if name == "pro-no-five-hour" { XCTAssertNil(value.selectedRateLimit?.primary) }
            if name == "unknown-plan" {
                XCTAssertEqual(value.selectedRateLimit?.planType, "future-plan")
                XCTAssertEqual(value.selectedRateLimit?.primary?.windowDurationMins, 4320)
            }
        }
    }
}
