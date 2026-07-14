import Foundation
import XCTest
@testable import CodexRateLimitsCore

final class QuotaForecastTests: XCTestCase {
    private let durationMinutes = 10_080

    func testWindowAverageForecastStaysOnPace() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let duration = TimeInterval(durationMinutes * 60)
        let window = makeWindow(resetAt: now.addingTimeInterval(duration * 0.5), remaining: 80)

        let forecast = try XCTUnwrap(QuotaForecastEngine.forecast(window: window, samples: [], now: now))

        XCTAssertEqual(forecast.status, .onPace)
        XCTAssertEqual(forecast.basis, .windowAverage)
        XCTAssertEqual(forecast.confidence, .high)
        XCTAssertEqual(forecast.budgetRemainingPercent, 50, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(forecast.projectedRemainingAtReset), 60, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(forecast.paceRatio), 0.4, accuracy: 0.001)
        XCTAssertNil(forecast.projectedExhaustionAt)
    }

    func testFastWindowAverageProjectsExhaustionBeforeReset() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let duration = TimeInterval(durationMinutes * 60)
        let window = makeWindow(resetAt: now.addingTimeInterval(duration * 0.75), remaining: 40)

        let forecast = try XCTUnwrap(QuotaForecastEngine.forecast(window: window, samples: [], now: now))

        XCTAssertEqual(forecast.status, .atRisk)
        XCTAssertEqual(forecast.confidence, .high)
        XCTAssertLessThan(try XCTUnwrap(forecast.projectedExhaustionAt), try XCTUnwrap(window.resetDate))
        XCTAssertEqual(try XCTUnwrap(forecast.projectedRemainingAtReset), 0, accuracy: 0.001)
    }

    func testRecentTrendOverridesSlowerWindowAverage() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let duration = TimeInterval(durationMinutes * 60)
        let window = makeWindow(resetAt: now.addingTimeInterval(duration * 0.5), remaining: 80)
        let windowID = try XCTUnwrap(QuotaWindowID(window: window))
        let samples = [
            QuotaSample(
                windowID: windowID,
                timestamp: now.addingTimeInterval(-2 * 60 * 60),
                usedPercent: 5,
                remainingPercent: 95
            ),
        ]

        let forecast = try XCTUnwrap(QuotaForecastEngine.forecast(window: window, samples: samples, now: now))

        XCTAssertEqual(forecast.basis, .recentTrend)
        XCTAssertEqual(forecast.confidence, .high)
        XCTAssertEqual(forecast.status, .atRisk)
        XCTAssertEqual(try XCTUnwrap(forecast.consumptionRatePercentPerHour), 7.5, accuracy: 0.001)
    }

    func testNoConsumptionProducesInsufficientForecast() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let duration = TimeInterval(durationMinutes * 60)
        let window = makeWindow(resetAt: now.addingTimeInterval(duration * 0.9), remaining: 100)

        let forecast = try XCTUnwrap(QuotaForecastEngine.forecast(window: window, samples: [], now: now))

        XCTAssertEqual(forecast.status, .insufficientData)
        XCTAssertNil(forecast.projectedRemainingAtReset)
        XCTAssertNil(forecast.projectedExhaustionAt)
    }

    func testWarningAndCriticalAlertsAreDeduplicated() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetAt = now.addingTimeInterval(3 * 24 * 60 * 60)
        let warningWindow = makeWindow(resetAt: resetAt, remaining: 25)

        let first = QuotaAlertEvaluator.evaluate(
            window: warningWindow,
            forecast: nil,
            previousState: QuotaAlertState(),
            alertsEnabled: true,
            now: now
        )
        XCTAssertEqual(first.events.map(\.kind), [.warning])

        let duplicate = QuotaAlertEvaluator.evaluate(
            window: warningWindow,
            forecast: nil,
            previousState: first.state,
            alertsEnabled: true,
            now: now.addingTimeInterval(60)
        )
        XCTAssertTrue(duplicate.events.isEmpty)

        let criticalWindow = makeWindow(resetAt: resetAt, remaining: 10)
        let critical = QuotaAlertEvaluator.evaluate(
            window: criticalWindow,
            forecast: nil,
            previousState: duplicate.state,
            alertsEnabled: true,
            now: now.addingTimeInterval(120)
        )
        XCTAssertEqual(critical.events.map(\.kind), [.critical])
        XCTAssertTrue(critical.state.deliveredKinds.contains(.warning))
        XCTAssertTrue(critical.state.deliveredKinds.contains(.critical))
    }

    func testActionableForecastAlertIsSentOnce() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let duration = TimeInterval(durationMinutes * 60)
        let window = makeWindow(resetAt: now.addingTimeInterval(duration * 0.75), remaining: 40)
        let forecast = try XCTUnwrap(QuotaForecastEngine.forecast(window: window, samples: [], now: now))

        let first = QuotaAlertEvaluator.evaluate(
            window: window,
            forecast: forecast,
            previousState: QuotaAlertState(),
            alertsEnabled: true,
            now: now
        )
        XCTAssertEqual(first.events.map(\.kind), [.projectedExhaustion])

        let duplicate = QuotaAlertEvaluator.evaluate(
            window: window,
            forecast: forecast,
            previousState: first.state,
            alertsEnabled: true,
            now: now.addingTimeInterval(60)
        )
        XCTAssertTrue(duplicate.events.isEmpty)
    }

    func testRealResetNotifiesButFutureWindowJitterDoesNot() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldReset = now.addingTimeInterval(60 * 60)
        let oldWindow = makeWindow(resetAt: oldReset, remaining: 70)
        let initial = QuotaAlertEvaluator.evaluate(
            window: oldWindow,
            forecast: nil,
            previousState: QuotaAlertState(),
            alertsEnabled: true,
            now: now
        )

        let jitteredWindow = makeWindow(resetAt: oldReset.addingTimeInterval(10 * 60), remaining: 70)
        let jittered = QuotaAlertEvaluator.evaluate(
            window: jitteredWindow,
            forecast: nil,
            previousState: initial.state,
            alertsEnabled: true,
            now: now.addingTimeInterval(60)
        )
        XCTAssertTrue(jittered.events.isEmpty)

        let afterReset = oldReset.addingTimeInterval(11 * 60)
        let newWindow = makeWindow(
            resetAt: afterReset.addingTimeInterval(TimeInterval(durationMinutes * 60)),
            remaining: 100
        )
        let reset = QuotaAlertEvaluator.evaluate(
            window: newWindow,
            forecast: nil,
            previousState: jittered.state,
            alertsEnabled: true,
            now: afterReset
        )
        XCTAssertEqual(reset.events.map(\.kind), [.reset])
    }

    func testOldResetDoesNotProduceStaleNotificationAfterLongOfflinePeriod() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldReset = now.addingTimeInterval(-2 * 24 * 60 * 60)
        let oldWindow = makeWindow(resetAt: oldReset, remaining: 20)
        let initial = QuotaAlertEvaluator.evaluate(
            window: oldWindow,
            forecast: nil,
            previousState: QuotaAlertState(),
            alertsEnabled: false,
            now: oldReset.addingTimeInterval(-60)
        )
        let currentWindow = makeWindow(
            resetAt: now.addingTimeInterval(5 * 24 * 60 * 60),
            remaining: 98
        )

        let resumed = QuotaAlertEvaluator.evaluate(
            window: currentWindow,
            forecast: nil,
            previousState: initial.state,
            alertsEnabled: true,
            now: now
        )

        XCTAssertTrue(resumed.events.isEmpty)
    }

    func testNearResetTimeCorrectionIsNotTreatedAsNewWindow() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldReset = now.addingTimeInterval(4 * 60)
        let warningWindow = makeWindow(resetAt: oldReset, remaining: 25)
        let initial = QuotaAlertEvaluator.evaluate(
            window: warningWindow,
            forecast: nil,
            previousState: QuotaAlertState(),
            alertsEnabled: true,
            now: now
        )
        XCTAssertEqual(initial.events.map(\.kind), [.warning])

        let correctedWindow = makeWindow(
            resetAt: oldReset.addingTimeInterval(10 * 60),
            remaining: 25
        )
        let corrected = QuotaAlertEvaluator.evaluate(
            window: correctedWindow,
            forecast: nil,
            previousState: initial.state,
            alertsEnabled: true,
            now: now.addingTimeInterval(60)
        )

        XCTAssertTrue(corrected.events.isEmpty)
        XCTAssertTrue(corrected.state.deliveredKinds.contains(.warning))
        XCTAssertFalse(corrected.state.deliveredKinds.contains(.reset))
    }

    func testMonitorPersistsHistoryAndAlertDedupe() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaMonitorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("quota-history.json")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetAt = now.addingTimeInterval(TimeInterval(durationMinutes * 30))
        let earlierWindow = makeWindow(resetAt: resetAt, remaining: 95)
        let currentWindow = makeWindow(resetAt: resetAt, remaining: 80)

        let firstMonitor = QuotaMonitor(fileURL: fileURL)
        _ = firstMonitor.update(
            window: earlierWindow,
            at: now.addingTimeInterval(-2 * 60 * 60),
            alertsEnabled: false
        )

        let secondMonitor = QuotaMonitor(fileURL: fileURL)
        let current = secondMonitor.update(window: currentWindow, at: now, alertsEnabled: true)
        XCTAssertEqual(current.sampleCount, 2)
        XCTAssertEqual(current.forecast?.basis, .recentTrend)
        XCTAssertEqual(current.alerts.map(\.kind), [.projectedExhaustion])

        let thirdMonitor = QuotaMonitor(fileURL: fileURL)
        let duplicate = thirdMonitor.update(
            window: currentWindow,
            at: now.addingTimeInterval(60),
            alertsEnabled: true
        )
        XCTAssertTrue(duplicate.alerts.isEmpty)
        XCTAssertEqual(duplicate.sampleCount, 2)
    }

    func testMonitorPreservesTrendWhenActiveResetTimeShifts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaMonitorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let monitor = QuotaMonitor(fileURL: directory.appendingPathComponent("quota-history.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetAt = now.addingTimeInterval(3 * 24 * 60 * 60)

        _ = monitor.update(
            window: makeWindow(resetAt: resetAt, remaining: 95),
            at: now.addingTimeInterval(-2 * 60 * 60),
            alertsEnabled: false
        )
        let shifted = monitor.update(
            window: makeWindow(resetAt: resetAt.addingTimeInterval(10 * 60), remaining: 80),
            at: now,
            alertsEnabled: false
        )

        XCTAssertEqual(shifted.sampleCount, 2)
        XCTAssertEqual(shifted.forecast?.basis, .recentTrend)
        XCTAssertNil(shifted.persistenceError)
    }

    func testPersistenceFailureDoesNotSuppressForecastOrAlert() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaMonitorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blockedParent = directory.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockedParent)
        let monitor = QuotaMonitor(fileURL: blockedParent.appendingPathComponent("quota-history.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = makeWindow(resetAt: now.addingTimeInterval(3 * 24 * 60 * 60), remaining: 25)

        let snapshot = monitor.update(window: window, at: now, alertsEnabled: true)

        XCTAssertNotNil(snapshot.forecast)
        XCTAssertEqual(snapshot.alerts.map(\.kind), [.warning])
        XCTAssertNotNil(snapshot.persistenceError)
    }

    private func makeWindow(resetAt: Date, remaining: Int) -> RateLimitWindow {
        RateLimitWindow(
            usedPercent: 100 - remaining,
            remainingPercent: remaining,
            windowDurationMins: durationMinutes,
            resetsAt: Int(resetAt.timeIntervalSince1970),
            resetsAtIso: nil
        )
    }
}
