import Foundation
import XCTest
@testable import CodexRateLimitsCore

final class AppServerCallStateTests: XCTestCase {
    func testEveryUTF8SplitPreservesResponseAndCompletesWithoutTimeout() throws {
        let expected = "é 中文 🙂 e\u{301} / 日本語 / 한국어"
        let data = Data("{\"id\":1,\"result\":{\"label\":\"\(expected)\"}}\n".utf8)
        for cut in 1..<data.count {
            let state = AppServerCallState(labelsById: [1: "account/read"])
            state.processStdout(Data(data.prefix(cut)))
            state.processStdout(Data(data.dropFirst(cut)))
            let completion = state.completion()
            XCTAssertNil(completion.error, "Cut at byte \(cut)")
            XCTAssertEqual((completion.results["account/read"] as? [String: Any])?["label"] as? String,
                           expected, "Cut at byte \(cut)")
            XCTAssertEqual(state.semaphore.wait(timeout: .now()), .success, "Cut at byte \(cut)")
        }
    }

    func testBytewiseStderrPreservesUnicodeAndUnterminatedTail() {
        let expected = "连接失败：é🙂\n最后一行尚无换行"
        let state = AppServerCallState(labelsById: [1: "initialize"])
        for byte in expected.utf8 { state.processStderr(Data([byte])) }
        XCTAssertEqual(state.stderrTail(), expected)
    }

    func testBytewiseOutOfOrderResponsesHandleCRLFNotificationsAndEscapedNewlines() {
        let state = AppServerCallState(labelsById: [1: "initialize", 2: "account/read", 3: "account/rateLimits/read"])
        let input = """
        startup text
        
        {"method":"notice","params":{"text":"通知🙂"}}
        {"id":3,"result":{"used":20}}
        {"id":1,"result":null}
        {"id":2,"result":{"label":"账户\\n第二行🙂"}}
        
        """.replacingOccurrences(of: "\n", with: "\r\n")
        for byte in input.utf8 { state.processStdout(Data([byte])) }
        let result = state.completion()
        XCTAssertNil(result.error)
        XCTAssertEqual(result.results.count, 3)
        XCTAssertTrue(result.results["initialize"] is NSNull)
        XCTAssertEqual((result.results["account/read"] as? [String: Any])?["label"] as? String, "账户\n第二行🙂")
        XCTAssertEqual((result.results["account/rateLimits/read"] as? [String: Any])?["used"] as? Int, 20)
        XCTAssertEqual(state.semaphore.wait(timeout: .now()), .success)
    }

    func testInvalidUTF8OrJSONOnlyDiscardsItsOwnLine() {
        let state = AppServerCallState(labelsById: [1: "account/read"])
        var input = Data("{\"id\":1,\"result\":\"".utf8)
        input.append(contentsOf: [0xFF, 0x80])
        input.append(Data("\"}\n{broken}\n{\"id\":1,\"result\":\"有效🙂\"}\n".utf8))
        state.processStdout(input)
        XCTAssertNil(state.completion().error)
        XCTAssertEqual(state.completion().results["account/read"] as? String, "有效🙂")
        XCTAssertEqual(state.semaphore.wait(timeout: .now()), .success)
    }

    func testDuplicateUnknownAndNotificationIDsDoNotCompleteOrOverwriteRequests() {
        let state = AppServerCallState(labelsById: [1: "initialize", 2: "account/read"])
        state.processStdout(Data("{\"id\":99,\"result\":\"unrelated\"}\n{\"method\":\"notice\"}\n{\"id\":1,\"result\":\"first\"}\n{\"id\":1,\"error\":\"duplicate\"}\n".utf8))
        XCTAssertNil(state.completion().error)
        XCTAssertEqual(state.completion().results["initialize"] as? String, "first")
        XCTAssertEqual(state.semaphore.wait(timeout: .now()), .timedOut)
        state.processStdout(Data("{\"id\":2,\"result\":\"second\"}\n".utf8))
        XCTAssertEqual(state.semaphore.wait(timeout: .now()), .success)
        XCTAssertEqual(state.completion().results.count, 2)
    }

    func testRPCErrorIsTerminalAndSignalsOnlyOnce() throws {
        let state = AppServerCallState(labelsById: [1: "initialize", 2: "account/read"])
        let input = Data("{\"id\":2,\"error\":{\"message\":\"请求失败🙂\"}}\n{\"id\":1,\"result\":{}}\n".utf8)
        for byte in input { state.processStdout(Data([byte])) }
        let error = try XCTUnwrap(state.completion().error).localizedDescription
        XCTAssertTrue(error.contains("account/read failed"))
        XCTAssertTrue(error.contains("请求失败🙂"))
        state.fail(RuntimeError("late exit"))
        state.processStdout(Data())
        XCTAssertEqual(state.completion().error?.localizedDescription, error)
        XCTAssertTrue(state.completion().results.isEmpty)
        XCTAssertEqual(state.semaphore.wait(timeout: .now()), .success)
        XCTAssertEqual(state.semaphore.wait(timeout: .now()), .timedOut)
    }

    func testSuccessCannotBeChangedByLateOutputOrTermination() {
        let state = AppServerCallState(labelsById: [1: "initialize"], maximumLineBytes: 64)
        state.processStdout(Data("{\"id\":1,\"result\":\"accepted\"}\n".utf8))
        state.fail(RuntimeError("process terminated after completion"))
        state.processStdout(Data(repeating: 0x78, count: 1000))
        state.processStdout(Data())
        XCTAssertNil(state.completion().error)
        XCTAssertEqual(state.completion().results["initialize"] as? String, "accepted")
        XCTAssertEqual(state.semaphore.wait(timeout: .now()), .success)
        XCTAssertEqual(state.semaphore.wait(timeout: .now()), .timedOut)
    }

    func testByteLimitAcceptsExactBoundaryAndRejectsOversizedLineWithOrWithoutLF() {
        let line = Data("{\"id\":1,\"result\":\"中文🙂\"}".utf8)
        let state = AppServerCallState(labelsById: [1: "initialize"], maximumLineBytes: line.count)
        state.processStdout(line)
        XCTAssertEqual(state.semaphore.wait(timeout: .now()), .timedOut)
        state.processStdout(Data([0x0A]))
        XCTAssertNil(state.completion().error)
        XCTAssertEqual(state.completion().results["initialize"] as? String, "中文🙂")
        for suffix in [Data(), Data([0x0A])] {
            let oversized = AppServerCallState(labelsById: [1: "initialize"], maximumLineBytes: line.count - 1)
            oversized.processStdout(line + suffix)
            XCTAssertTrue(oversized.completion().error?.localizedDescription.contains("exceeded \(line.count - 1) bytes") == true)
            XCTAssertEqual(oversized.semaphore.wait(timeout: .now()), .success)
            XCTAssertTrue(oversized.completion().results.isEmpty)
        }
    }

    func testLineLimitAppliesAcrossChunksAndResetsAfterEachCompleteLine() {
        let state = AppServerCallState(labelsById: [1: "initialize"], maximumLineBytes: 64)
        let messages = String(repeating: "{\"method\":\"通知🙂\"}\n", count: 1000)
            + "{\"id\":1,\"result\":true}\n"
        state.processStdout(Data(messages.utf8))
        XCTAssertNil(state.completion().error)
        XCTAssertEqual(state.completion().results["initialize"] as? Bool, true)
        let oversized = AppServerCallState(labelsById: [1: "initialize"], maximumLineBytes: 64)
        for _ in 0..<8 { oversized.processStdout(Data(repeating: 0x78, count: 8)) }
        XCTAssertNil(oversized.completion().error)
        oversized.processStdout(Data([0x78]))
        XCTAssertNotNil(oversized.completion().error)
        XCTAssertEqual(oversized.semaphore.wait(timeout: .now()), .success)
    }

    func testEOFCompletesFinalResponseWithoutNewline() {
        let state = AppServerCallState(labelsById: [1: "initialize"])
        state.processStdout(Data("{\"id\":1,\"result\":\"最后🙂\"}".utf8))
        XCTAssertEqual(state.semaphore.wait(timeout: .now()), .timedOut)
        state.processStdout(Data())
        XCTAssertNil(state.completion().error)
        XCTAssertEqual(state.completion().results["initialize"] as? String, "最后🙂")
        XCTAssertEqual(state.semaphore.wait(timeout: .now()), .success)
    }

    func testEOFFailsMissingOrTruncatedResponseImmediatelyWithAvailableStderr() throws {
        for partial in [Data(), Data("{\"id\":2,\"result\":".utf8), Data([0xF0, 0x9F])] {
            let state = AppServerCallState(labelsById: [1: "initialize", 2: "account/read"])
            state.processStdout(Data("{\"id\":1,\"result\":{}}\n".utf8))
            state.processStderr(Data("连接中断🙂".utf8))
            if !partial.isEmpty { state.processStdout(partial) }
            state.processStdout(Data())
            let error = try XCTUnwrap(state.completion().error).localizedDescription
            XCTAssertTrue(error.contains("stdout ended before returning account/read"))
            XCTAssertTrue(error.contains("连接中断🙂"))
            XCTAssertEqual(state.semaphore.wait(timeout: .now()), .success)
        }
    }

    func testStderrRetainsOnlyBoundedBytesAndLastFiftyLines() {
        let bytes = AppServerCallState(labelsById: [1: "initialize"], maximumStderrBytes: 16)
        bytes.processStderr(Data(repeating: 0x78, count: 100_000))
        XCTAssertEqual(bytes.stderrTail(), String(repeating: "x", count: 16))
        bytes.processStderr(Data("最终🙂".utf8))
        XCTAssertEqual(bytes.stderrTail(), String(repeating: "x", count: 6) + "最终🙂")
        let lines = AppServerCallState(labelsById: [1: "initialize"])
        lines.processStderr(Data((1...100).map { "line\($0)\r\n" }.joined().utf8))
        XCTAssertEqual(lines.stderrTail(), (51...100).map { "line\($0)" }.joined(separator: "\n"))
        lines.processStderr(Data("last partial🙂".utf8))
        XCTAssertEqual(lines.stderrTail().components(separatedBy: "\n").count, 50)
        XCTAssertTrue(lines.stderrTail().hasSuffix("last partial🙂"))
    }

    func testStderrInvalidBytesDoNotEraseFollowingDiagnostics() {
        let state = AppServerCallState(labelsById: [1: "initialize"])
        state.processStderr(Data([0xFF]) + Data("诊断🙂".utf8))
        XCTAssertTrue(state.stderrTail().hasSuffix("诊断🙂"))
    }
}
