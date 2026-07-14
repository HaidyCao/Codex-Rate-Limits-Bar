import Foundation
import XCTest
@testable import CodexRateLimitsCore

final class LocalUsageScannerTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var calendar: Calendar!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRateLimitsCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testPreviousDayUsageOnlyProvidesTodaysBaseline() throws {
        let now = try date("2026-07-13T17:00:00Z")
        let file = temporaryDirectory.appendingPathComponent("rollout-cross-day.jsonl")
        try writeEvents([
            sessionMeta(id: "session-a", timestamp: "2026-07-13T15:58:00Z"),
            tokenCount(total: 100, timestamp: "2026-07-13T15:59:00Z"),
            tokenCount(total: 240, timestamp: "2026-07-13T16:01:00Z"),
        ], to: file, modifiedAt: now)

        let snapshot = try scanner(now: { now }).snapshot()

        XCTAssertEqual(snapshot.localDate, "2026-07-14")
        XCTAssertEqual(snapshot.timezone, "Asia/Shanghai")
        XCTAssertEqual(snapshot.totalTokens, 140)
        XCTAssertEqual(snapshot.eventCount, 1)
    }

    func testCacheResetsAtLocalMidnightWithoutLosingBaseline() throws {
        let clock = TestClock(try date("2026-07-13T14:30:00Z"))
        let file = temporaryDirectory.appendingPathComponent("rollout-midnight.jsonl")
        try writeEvents([
            sessionMeta(id: "session-a", timestamp: "2026-07-13T12:00:00Z"),
            tokenCount(total: 100, timestamp: "2026-07-13T13:00:00Z"),
            tokenCount(total: 150, timestamp: "2026-07-13T14:00:00Z"),
        ], to: file, modifiedAt: clock.now)
        let scanner = scanner(now: { clock.now })

        let firstDay = try scanner.snapshot()
        XCTAssertEqual(firstDay.localDate, "2026-07-13")
        XCTAssertEqual(firstDay.totalTokens, 150)

        clock.now = try date("2026-07-13T16:30:00Z")
        try appendEvent(tokenCount(total: 210, timestamp: "2026-07-13T16:10:00Z"), to: file, modifiedAt: clock.now)

        let secondDay = try scanner.snapshot()
        XCTAssertEqual(secondDay.localDate, "2026-07-14")
        XCTAssertEqual(secondDay.totalTokens, 60)
        XCTAssertEqual(secondDay.eventCount, 1)
    }

    func testTimeZoneChangeInvalidatesCachedDayBoundaries() throws {
        let now = try date("2026-07-13T16:30:00Z")
        let calendarClock = TestCalendar(calendar)
        let file = temporaryDirectory.appendingPathComponent("rollout-time-zone.jsonl")
        try writeEvents([
            sessionMeta(id: "session-a", timestamp: "2026-07-13T15:45:00Z"),
            tokenCount(total: 100, timestamp: "2026-07-13T15:50:00Z"),
            tokenCount(total: 150, timestamp: "2026-07-13T16:10:00Z"),
        ], to: file, modifiedAt: now)
        let scanner = CodexBackend.LocalUsageScanner(
            rootURLs: [temporaryDirectory],
            calendarProvider: { calendarClock.value },
            now: { now }
        )

        calendarClock.value.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let utcSnapshot = try scanner.snapshot()
        XCTAssertEqual(utcSnapshot.localDate, "2026-07-13")
        XCTAssertEqual(utcSnapshot.totalTokens, 150)

        calendarClock.value.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let shanghaiSnapshot = try scanner.snapshot()
        XCTAssertEqual(shanghaiSnapshot.localDate, "2026-07-14")
        XCTAssertEqual(shanghaiSnapshot.totalTokens, 50)
    }

    func testForkedHistoryIsBaselineButNotConsumption() throws {
        let now = try date("2026-07-14T04:00:00Z")
        let file = temporaryDirectory.appendingPathComponent("rollout-fork.jsonl")
        try writeEvents([
            sessionMeta(id: "fork-session", timestamp: "2026-07-14T00:00:00Z"),
            sessionMeta(id: "parent-session", timestamp: "2026-07-14T00:01:00Z"),
            tokenCount(total: 1_000, timestamp: "2026-07-14T00:02:00Z"),
            tokenCount(total: 1_200, timestamp: "2026-07-14T00:03:00Z"),
            tokenCount(total: 900, timestamp: "2026-07-14T00:04:00Z"),
            sessionMeta(id: "fork-session", timestamp: "2026-07-14T00:05:00Z"),
            tokenCount(total: 910, timestamp: "2026-07-14T00:06:00Z"),
            tokenCount(total: 950, timestamp: "2026-07-14T00:07:00Z"),
        ], to: file, modifiedAt: now)

        let snapshot = try scanner(now: { now }).snapshot()

        XCTAssertEqual(snapshot.totalTokens, 50)
        XCTAssertEqual(snapshot.importedEventCount, 3)
        XCTAssertEqual(snapshot.eventCount, 2)
        XCTAssertEqual(snapshot.topFiles?.first?.primarySessionId, "fork-session")
    }

    func testRegressionDoesNotRecountWholeSession() throws {
        let now = try date("2026-07-14T04:00:00Z")
        let file = temporaryDirectory.appendingPathComponent("rollout-regression.jsonl")
        try writeEvents([
            sessionMeta(id: "session-a", timestamp: "2026-07-14T00:00:00Z"),
            tokenCount(total: 100, timestamp: "2026-07-14T00:01:00Z"),
            tokenCount(total: 90, timestamp: "2026-07-14T00:02:00Z"),
            tokenCount(total: 110, timestamp: "2026-07-14T00:03:00Z"),
        ], to: file, modifiedAt: now)

        let snapshot = try scanner(now: { now }).snapshot()

        XCTAssertEqual(snapshot.totalTokens, 110)
        XCTAssertEqual(snapshot.eventCount, 3)
        XCTAssertEqual(snapshot.duplicateEventCount, 1)
        XCTAssertEqual(snapshot.regressionEventCount, 1)
    }

    func testIncompleteLineIsProcessedAfterNextIncrementalRead() throws {
        let now = try date("2026-07-14T04:00:00Z")
        let file = temporaryDirectory.appendingPathComponent("rollout-partial.jsonl")
        var initialData = try jsonData(sessionMeta(id: "session-a", timestamp: "2026-07-14T00:00:00Z"))
        initialData.append(0x0A)
        initialData.append(try jsonData(tokenCount(total: 100, timestamp: "2026-07-14T00:01:00Z")))
        try initialData.write(to: file)
        try setModificationDate(now, for: file)
        let scanner = scanner(now: { now })

        XCTAssertEqual(try scanner.snapshot().totalTokens, 0)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x0A]))
        try handle.close()
        try setModificationDate(now, for: file)

        let completedSnapshot = try scanner.snapshot()
        XCTAssertEqual(completedSnapshot.totalTokens, 100)
        XCTAssertEqual(completedSnapshot.eventCount, 1)
    }

    func testPersistentCacheSurvivesProcessRestart() throws {
        let now = try date("2026-07-14T04:00:00Z")
        let file = temporaryDirectory.appendingPathComponent("rollout-persisted.jsonl")
        let cacheFile = temporaryDirectory.appendingPathComponent("local-usage-cache.json")
        try writeEvents([
            sessionMeta(id: "session-a", timestamp: "2026-07-14T00:00:00Z"),
            tokenCount(total: 100, timestamp: "2026-07-14T00:01:00Z"),
        ], to: file, modifiedAt: now)

        let firstScanner = CodexBackend.LocalUsageScanner(
            rootURLs: [temporaryDirectory],
            calendar: calendar,
            now: { now },
            cacheFileURL: cacheFile
        )
        XCTAssertEqual(try firstScanner.snapshot().totalTokens, 100)

        let originalSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        ).intValue
        var replacement = Data(repeating: 0x23, count: originalSize)
        replacement[replacement.index(before: replacement.endIndex)] = 0x0A
        try replacement.write(to: file)
        try setModificationDate(now, for: file)

        let restartedScanner = CodexBackend.LocalUsageScanner(
            rootURLs: [temporaryDirectory],
            calendar: calendar,
            now: { now },
            cacheFileURL: cacheFile
        )
        let restored = try restartedScanner.snapshot()

        XCTAssertEqual(restored.totalTokens, 100)
        XCTAssertEqual(restored.eventCount, 1)
    }

    func testPersistentCacheCarriesBaselineAcrossMidnightAndRestart() throws {
        let clock = TestClock(try date("2026-07-13T15:30:00Z"))
        let file = temporaryDirectory.appendingPathComponent("rollout-persisted-midnight.jsonl")
        let cacheFile = temporaryDirectory.appendingPathComponent("local-usage-cache.json")
        try writeEvents([
            sessionMeta(id: "session-a", timestamp: "2026-07-13T14:00:00Z"),
            tokenCount(total: 100, timestamp: "2026-07-13T15:00:00Z"),
        ], to: file, modifiedAt: clock.now)

        let firstScanner = CodexBackend.LocalUsageScanner(
            rootURLs: [temporaryDirectory],
            calendar: calendar,
            now: { clock.now },
            cacheFileURL: cacheFile
        )
        XCTAssertEqual(try firstScanner.snapshot().totalTokens, 100)

        clock.now = try date("2026-07-13T17:00:00Z")
        try appendEvent(
            tokenCount(total: 150, timestamp: "2026-07-13T16:30:00Z"),
            to: file,
            modifiedAt: clock.now
        )
        let nextDayScanner = CodexBackend.LocalUsageScanner(
            rootURLs: [temporaryDirectory],
            calendar: calendar,
            now: { clock.now },
            cacheFileURL: cacheFile
        )
        let nextDay = try nextDayScanner.snapshot()

        XCTAssertEqual(nextDay.localDate, "2026-07-14")
        XCTAssertEqual(nextDay.totalTokens, 50)
        XCTAssertEqual(nextDay.eventCount, 1)
    }

    func testLargeIrrelevantLineAcrossReadChunksIsSkipped() throws {
        let now = try date("2026-07-14T04:00:00Z")
        let file = temporaryDirectory.appendingPathComponent("rollout-large-line.jsonl")
        var data = try jsonData(sessionMeta(id: "session-a", timestamp: "2026-07-14T00:00:00Z"))
        data.append(0x0A)
        data.append(Data("{\"timestamp\":\"2026-07-14T00:00:30Z\",\"type\":\"response_item\",\"payload\":{\"text\":\"".utf8))
        data.append(Data(repeating: 0x78, count: 5 * 1_024 * 1_024))
        data.append(Data("\"}}\n".utf8))
        data.append(try jsonData(tokenCount(total: 100, timestamp: "2026-07-14T00:01:00Z")))
        data.append(0x0A)
        try data.write(to: file)
        try setModificationDate(now, for: file)

        let snapshot = try scanner(now: { now }).snapshot()

        XCTAssertEqual(snapshot.totalTokens, 100)
        XCTAssertEqual(snapshot.eventCount, 1)
        XCTAssertEqual(snapshot.parseErrorCount, 0)
    }

    private func scanner(now: @escaping () -> Date) -> CodexBackend.LocalUsageScanner {
        CodexBackend.LocalUsageScanner(rootURLs: [temporaryDirectory], calendar: calendar, now: now)
    }

    private func sessionMeta(id: String, timestamp: String) -> [String: Any] {
        [
            "timestamp": timestamp,
            "type": "session_meta",
            "payload": ["id": id],
        ]
    }

    private func tokenCount(total: Int64, timestamp: String) -> [String: Any] {
        [
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": total,
                        "cached_input_tokens": 0,
                        "output_tokens": 0,
                        "reasoning_output_tokens": 0,
                        "total_tokens": total,
                    ],
                ],
            ],
        ]
    }

    private func writeEvents(_ events: [[String: Any]], to file: URL, modifiedAt: Date) throws {
        var data = Data()
        for event in events {
            data.append(try jsonData(event))
            data.append(0x0A)
        }
        try data.write(to: file)
        try setModificationDate(modifiedAt, for: file)
    }

    private func appendEvent(_ event: [String: Any], to file: URL, modifiedAt: Date) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: jsonData(event))
        try handle.write(contentsOf: Data([0x0A]))
        try handle.close()
        try setModificationDate(modifiedAt, for: file)
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func setModificationDate(_ date: Date, for file: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: value))
    }
}

private final class TestClock: @unchecked Sendable {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private final class TestCalendar: @unchecked Sendable {
    var value: Calendar

    init(_ value: Calendar) {
        self.value = value
    }
}
