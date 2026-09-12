import Darwin
import Foundation
import XCTest
@testable import CodexRateLimitsCore

final class ScannerPerformanceTests: XCTestCase {
    func testSparseCopiedHistoriesStayCompactAndMatchRebuild() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["USAGE_RUN_BENCHMARKS"] == "1", "Run make benchmark for copied-history performance.")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CopyBenchmark-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache.json")
        let now = ISO8601DateFormatter().date(from: "2026-09-11T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func scanner() -> LocalUsageScanner {
            LocalUsageScanner(rootURLs: [root], calendar: calendar, now: { now }, cacheFileURL: cache)
        }
        let count = 20_000
        let header = Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"copy-benchmark\"}}\n".utf8)
        func event(_ index: Int) -> Data {
            Data("{\"timestamp\":\"2026-09-11T11:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"model\":\"gpt-5.6-sol\",\"service_tier\":\"standard\",\"total_token_usage\":{\"input_tokens\":\(index * 10),\"total_tokens\":\(index * 10)},\"last_token_usage\":{\"input_tokens\":10}}}}\n".utf8)
        }
        var paths: [URL] = []
        for copy in 0..<6 {
            let path = root.appendingPathComponent("\(copy).jsonl")
            paths.append(path)
            try header.write(to: path)
            let handle = try FileHandle(forWritingTo: path)
            try handle.seekToEnd()
            for index in 1...count where index == count || (index * 17 + copy * 5) % 7 < 3 {
                try handle.write(contentsOf: event(index))
            }
            try handle.close()
        }
        for copy in 6..<8 {
            let path = root.appendingPathComponent("\(copy).jsonl")
            try FileManager.default.copyItem(at: paths[0], to: path)
            paths.append(path)
        }
        var timings: [String: Double] = [:]
        func measure(_ name: String, _ body: () throws -> LocalUsageSnapshot) rethrows -> LocalUsageSnapshot {
            let start = ProcessInfo.processInfo.systemUptime
            let value = try body()
            timings[name] = ProcessInfo.processInfo.systemUptime - start
            return value
        }
        func check(_ value: LocalUsageSnapshot, events: Int) throws {
            XCTAssertEqual(value.totalTokens, Int64(events * 10))
            XCTAssertEqual(value.diagnostics?.status, .complete)
            XCTAssertEqual(try XCTUnwrap(value.todayCost?.estimatedCostUSD), Double(events * 10) * 0.000004, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(value.todayCredits?.estimatedCredits), Double(events * 10) * 0.0001, accuracy: 1e-8)
        }
        let reader = scanner()
        try check(measure("coldSeconds") { try reader.snapshot() }, events: count)
        try check(measure("unchangedSeconds") { try reader.snapshot() }, events: count)
        try check(measure("restartSeconds") { try scanner().snapshot() }, events: count)
        for path in paths {
            let handle = try FileHandle(forWritingTo: path)
            try handle.seekToEnd(); try handle.write(contentsOf: event(count + 1)); try handle.close()
        }
        let appended = try measure("appendSeconds") { try reader.snapshot() }
        let rebuilt = try measure("rebuildSeconds") { try reader.snapshot(rebuild: true) }
        try check(appended, events: count + 1); try check(rebuilt, events: count + 1)
        let matches = appended.totalTokens == rebuilt.totalTokens && appended.todayCost?.estimatedCostUSD == rebuilt.todayCost?.estimatedCostUSD
            && appended.todayCredits?.estimatedCredits == rebuilt.todayCredits?.estimatedCredits && appended.eventCount == rebuilt.eventCount
        XCTAssertTrue(matches)
        let cacheBytes = try Data(contentsOf: cache).count
        var usage = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
        XCTAssertLessThan(cacheBytes, 1_048_576)
        XCTAssertLessThan(usage.ru_maxrss, 256 * 1_048_576)
        var report: [String: Any] = ["fullHistorySamples": count, "copies": paths.count,
            "cacheBytes": cacheBytes, "peakRSSBytes": usage.ru_maxrss, "resultsMatch": matches, "totalTokens": rebuilt.totalTokens]
        report.merge(timings) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let path = ProcessInfo.processInfo.environment["USAGE_BENCHMARK_OUTPUT"] {
            let file = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("benchmark-copies.json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        print("Copied-history benchmark:\n" + String(decoding: data, as: UTF8.self))
    }

    func testSyntheticLargeLogRemainsBoundedAndIncrementalResultsMatchRebuild() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["USAGE_RUN_BENCHMARKS"] == "1", "Run make benchmark for the synthetic large-log check.")
        let mib = Int(ProcessInfo.processInfo.environment["USAGE_BENCHMARK_MIB"] ?? "256") ?? 256
        guard (16...4096).contains(mib) else { XCTFail("USAGE_BENCHMARK_MIB must be between 16 and 4096"); return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScannerBenchmark-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.jsonl"), cache = root.appendingPathComponent("cache.json")
        let now = ISO8601DateFormatter().date(from: "2026-09-11T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func scanner() -> LocalUsageScanner {
            LocalUsageScanner(rootURLs: [root], calendar: calendar, now: { now }, cacheFileURL: cache)
        }
        func event(_ total: Int) throws -> Data {
            let event: [String: Any] = ["timestamp": "2026-09-11T11:00:00Z", "type": "event_msg",
                "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": total, "total_tokens": total],
                    "last_token_usage": ["input_tokens": 1000, "total_tokens": 1000]]]]
            return try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) + Data([10])
        }
        // Reuse a fixed buffer to generate the fixture; never allocate the full log.
        let padding = Data(("{\"payload\":{\"text\":\"" + String(repeating: "x", count: 512 * 1024) + "\"},\"type\":\"response_item\"}\n").utf8)
        let header = Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"benchmark\"}}\n{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.6-sol\",\"service_tier\":\"standard\"}}\n".utf8)
        try header.write(to: file)
        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd()
        for index in 1...mib {
            try writer.write(contentsOf: padding); try writer.write(contentsOf: padding)
            try writer.write(contentsOf: event(index * 1000))
        }
        try writer.close()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        var timings: [String: Double] = [:]
        func measure(_ name: String, _ body: () throws -> LocalUsageSnapshot) rethrows -> LocalUsageSnapshot {
            let start = ProcessInfo.processInfo.systemUptime
            let value = try body()
            timings[name] = ProcessInfo.processInfo.systemUptime - start
            return value
        }
        func check(_ value: LocalUsageSnapshot, total: Int64) {
            XCTAssertEqual(value.totalTokens, total)
            XCTAssertEqual(value.diagnostics?.status, .complete)
            XCTAssertNil(value.error)
        }
        let subject = scanner()
        let cold = try measure("coldSeconds") { try subject.snapshot() }
        let warm = try measure("unchangedSeconds") { try subject.snapshot() }
        let restarted = try measure("restartSeconds") { try scanner().snapshot() }
        for value in [cold, warm, restarted] { check(value, total: Int64(mib * 1000)) }
        let append = try FileHandle(forWritingTo: file)
        try append.seekToEnd(); try append.write(contentsOf: event((mib + 1) * 1000)); try append.close()
        let incremental = try measure("appendSeconds") { try subject.snapshot() }
        let rebuilt = try measure("rebuildSeconds") { try subject.snapshot(rebuild: true) }
        for value in [incremental, rebuilt] { check(value, total: Int64((mib + 1) * 1000)) }
        let matches = incremental.totalTokens == rebuilt.totalTokens
            && incremental.todayCost?.estimatedCostUSD == rebuilt.todayCost?.estimatedCostUSD
            && incremental.todayCredits?.estimatedCredits == rebuilt.todayCredits?.estimatedCredits
            && incremental.eventCount == rebuilt.eventCount
        XCTAssertTrue(matches, "Incremental and rebuilt amounts differ")
        let cacheBytes = try Data(contentsOf: cache).count
        var usage = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
        // A broad memory/cache guard catches whole-file/event-history retention;
        // time is reported, not gated by hardware-sensitive thresholds.
        XCTAssertLessThan(cacheBytes, 1_048_576)
        XCTAssertLessThan(usage.ru_maxrss, 256 * 1_048_576)
        var report: [String: Any] = ["fixtureMiB": mib, "cacheBytes": cacheBytes, "peakRSSBytes": usage.ru_maxrss,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "wordSizeBits": MemoryLayout<Int>.size * 8,
            "totalTokens": rebuilt.totalTokens, "resultsMatch": matches]
        report.merge(timings) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let path = ProcessInfo.processInfo.environment["USAGE_BENCHMARK_OUTPUT"] {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        print("Scanner benchmark:\n" + String(decoding: data, as: UTF8.self))
    }
}
