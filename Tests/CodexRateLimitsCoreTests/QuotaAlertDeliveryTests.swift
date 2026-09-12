import Foundation
import XCTest
@testable import CodexRateLimitsCore

final class QuotaAlertDeliveryTests: XCTestCase {
    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var fileURL: URL { directory.appendingPathComponent("history.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testUnconfirmedThresholdSurvivesRestartAndReevaluatesCurrentQuota() throws {
        let window = window(remaining: 25)
        let first = QuotaMonitor(fileURL: fileURL).update(window: window, at: now, alertsEnabled: true)
        XCTAssertEqual(first.alerts.map(\.kind), [.warning])
        let json = try history()
        let state = try XCTUnwrap(json["alertState"] as? [String: Any])
        XCTAssertEqual(state["deliveredKinds"] as? [String], [])
        XCTAssertNotNil(state["pendingAlert"])
        let restarted = QuotaMonitor(fileURL: fileURL)
        XCTAssertEqual(restarted.update(window: window, at: now, alertsEnabled: true).alerts.map(\.kind), [.warning])
        XCTAssertTrue(restarted.update(window: self.window(remaining: 100), at: now, alertsEnabled: true).alerts.isEmpty)
        XCTAssertTrue(restarted.update(window: window, at: now, alertsEnabled: false).alerts.isEmpty)
        XCTAssertEqual(restarted.update(window: window, at: now, alertsEnabled: true).alerts.map(\.kind), [.warning])
    }

    func testResetRetrySurvivesRestartButExpiresAfterResetGracePeriod() throws {
        let oldReset = now.addingTimeInterval(60)
        let monitor = QuotaMonitor(fileURL: fileURL)
        _ = monitor.update(window: window(remaining: 5, reset: oldReset), at: now, alertsEnabled: false)
        let fresh = window(remaining: 100, reset: oldReset.addingTimeInterval(604800))
        let first = monitor.update(window: fresh, at: oldReset.addingTimeInterval(1), alertsEnabled: true)
        XCTAssertEqual(first.alerts.map(\.kind), [.reset])
        let restarted = QuotaMonitor(fileURL: fileURL)
        XCTAssertEqual(restarted.update(window: fresh, at: oldReset.addingTimeInterval(60), alertsEnabled: true).alerts.map(\.kind), [.reset])
        XCTAssertTrue(restarted.update(window: fresh, at: oldReset.addingTimeInterval(901), alertsEnabled: true).alerts.isEmpty)
    }

    func testResetConfirmationPersistsAndTimeCorrectionPreservesDedupe() throws {
        let oldReset = now.addingTimeInterval(60)
        let monitor = QuotaMonitor(fileURL: fileURL)
        _ = monitor.update(window: window(remaining: 5, reset: oldReset), at: now, alertsEnabled: false)
        let freshReset = oldReset.addingTimeInterval(604800)
        let result = monitor.update(window: window(remaining: 100, reset: freshReset), at: oldReset, alertsEnabled: true)
        XCTAssertNil(monitor.acknowledge(try XCTUnwrap(result.alerts.first)))
        let restarted = QuotaMonitor(fileURL: fileURL).update(
            window: window(remaining: 100, reset: freshReset.addingTimeInterval(600)), at: oldReset.addingTimeInterval(60), alertsEnabled: true)
        XCTAssertTrue(restarted.alerts.isEmpty)
    }

    func testCriticalConfirmationCoversWarningAndActionableForecastOnlyAfterAcceptance() throws {
        let monitor = QuotaMonitor(fileURL: fileURL)
        let critical = window(remaining: 10)
        let pending = monitor.update(window: critical, at: now, alertsEnabled: true)
        XCTAssertEqual(pending.alerts.map(\.kind), [.critical])
        XCTAssertEqual(monitor.update(window: critical, at: now, alertsEnabled: true).alerts.map(\.kind), [.critical])
        XCTAssertNil(monitor.acknowledge(try XCTUnwrap(pending.alerts.first)))
        XCTAssertTrue(monitor.update(window: critical, at: now, alertsEnabled: true).alerts.isEmpty)
        let state = try XCTUnwrap(try history()["alertState"] as? [String: Any])
        XCTAssertEqual(Set(state["deliveredKinds"] as? [String] ?? []), ["warning", "critical", "projectedExhaustion"])
        XCTAssertNil(state["pendingAlert"])
    }

    func testOldScopeAndOldWindowAcknowledgementsCannotSuppressCurrentReminder() throws {
        let monitor = QuotaMonitor(fileURL: fileURL)
        func context(_ key: String) -> CodexAccountContext {
            CodexAccountContext(codexHome: "/fixture", authenticationSource: "/fixture/auth.json",
                accountKey: key, accountLabel: nil, limitID: "codex")
        }
        let first = monitor.update(window: window(remaining: 25), at: now, alertsEnabled: true, accountContext: context("a"))
        let old = try XCTUnwrap(first.alerts.first)
        _ = monitor.update(window: window(remaining: 25), at: now, alertsEnabled: true, accountContext: context("b"))
        XCTAssertNil(monitor.acknowledge(old))
        XCTAssertEqual(monitor.update(window: window(remaining: 25), at: now, alertsEnabled: true, accountContext: context("b")).alerts.map(\.kind), [.warning])
        let newWindow = window(remaining: 25, reset: old.resetAt.addingTimeInterval(604800))
        _ = monitor.update(window: newWindow, at: now, alertsEnabled: true, accountContext: context("a"))
        XCTAssertNil(monitor.acknowledge(old))
        XCTAssertEqual(monitor.update(window: newWindow, at: now, alertsEnabled: true, accountContext: context("a")).alerts.map(\.kind), [.warning])
    }

    func testFailedAcknowledgementWriteRetriesWithoutNewSample() throws {
        let monitor = QuotaMonitor(fileURL: fileURL)
        let current = window(remaining: 25)
        let first = monitor.update(window: current, at: now, alertsEnabled: true)
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
        XCTAssertNotNil(monitor.acknowledge(try XCTUnwrap(first.alerts.first)))
        XCTAssertTrue(monitor.update(window: current, at: now, alertsEnabled: true).alerts.isEmpty,
                      "Accepted notifications stay deduplicated in memory if persistence fails")
        try FileManager.default.removeItem(at: fileURL)
        let recovered = monitor.update(window: current, at: now, alertsEnabled: true)
        XCTAssertNil(recovered.persistenceError)
        XCTAssertEqual(recovered.sampleCount, first.sampleCount)
        XCTAssertTrue(QuotaMonitor(fileURL: fileURL).update(window: current, at: now, alertsEnabled: true).alerts.isEmpty)
    }

    func testLegacyHistoryWithoutPendingFieldsKeepsSamplesAndDeliveredKinds() throws {
        let current = window(remaining: 25)
        let id = try XCTUnwrap(QuotaWindowID(window: current))
        let rawID: [String: Any] = ["durationMinutes": id.durationMinutes, "resetAtBucket": id.resetAtBucket]
        let legacy: [String: Any] = ["version": 1,
            "samples": [["windowID": rawID, "timestamp": now.timeIntervalSince1970, "usedPercent": 75, "remainingPercent": 25]],
            "alertState": ["windowID": rawID, "resetAt": current.resetDate!.timeIntervalSince1970,
                           "deliveredKinds": ["warning", "projectedExhaustion"], "lastRemainingPercent": 25]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: fileURL)
        let result = QuotaMonitor(fileURL: fileURL).update(window: current, at: now, alertsEnabled: true)
        XCTAssertEqual(result.sampleCount, 1)
        XCTAssertTrue(result.alerts.isEmpty)
        XCTAssertNil(result.persistenceError)
    }

    func testExpiredQuotaCannotProduceThresholdReminder() {
        let result = QuotaMonitor(fileURL: fileURL).update(
            window: window(remaining: 0, reset: now.addingTimeInterval(-1)), at: now, alertsEnabled: true)
        XCTAssertTrue(result.alerts.isEmpty)
    }

    private func window(remaining: Int, reset: Date? = nil) -> RateLimitWindow {
        RateLimitWindow(usedPercent: 100 - remaining, remainingPercent: remaining, windowDurationMins: 10080,
            resetsAt: Int((reset ?? now.addingTimeInterval(3 * 86400)).timeIntervalSince1970), resetsAtIso: nil)
    }

    private func history() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
    }
}
