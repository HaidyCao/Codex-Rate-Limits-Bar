import Foundation
import XCTest
import Darwin
@testable import CodexRateLimitsCore

final class CodexPluginCommandTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testRunnerPreservesSelectedProfileAndFoundationIsolation() throws {
        let output = try run(#"printf '%s\n%s\n' "$CODEX_HOME" "$CFFIXED_USER_HOME""#)
        XCTAssertEqual(output.components(separatedBy: "\n").first, root.path)
        XCTAssertEqual(output.components(separatedBy: "\n")[1], ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"])
    }

    func testUnicodeOutputAndNonzeroErrorArePreserved() throws {
        XCTAssertEqual(try run("printf '完成 🚀'"), "完成 🚀")
        XCTAssertThrowsError(try run("printf '安装中断 🚫' >&2; exit 7")) {
            XCTAssertTrue(errorMessage($0).contains("安装中断 🚫"))
            XCTAssertTrue(errorMessage($0).contains("exit 7"))
        }
    }

    func testTimeoutStopsTermIgnoringProcessBeforeReturning() throws {
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try run(#"echo $$ > "$CODEX_HOME/pid"; trap '' TERM; while :; do :; done"#, timeout: 0.3)) {
            XCTAssertTrue(errorMessage($0).contains("timed out"))
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 5)
        let pidText = try String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8)
        let pid = try XCTUnwrap(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testOversizedOutputFailsWithoutHangingOnPipe() throws {
        XCTAssertThrowsError(try run("/bin/dd if=/dev/zero bs=1048576 count=9 2>/dev/null")) {
            XCTAssertTrue(errorMessage($0).contains("exceeded 8 MiB"))
        }
    }

    func testFailedLaunchReportsError() throws {
        XCTAssertThrowsError(try CodexPluginCommand.run(args: [], home: root, codexHome: root,
            command: (root.appendingPathComponent("missing-executable").path, [])))
    }

    private func run(_ script: String, timeout: TimeInterval = 5) throws -> String {
        try CodexPluginCommand.run(args: [], home: root, codexHome: root,
                                   command: ("/bin/sh", ["-c", script]), timeout: timeout)
    }
}
