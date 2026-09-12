import Foundation
import Darwin

enum CodexPluginCommand {
    static func run(
        args: [String], home: URL, codexHome: URL,
        command: (executable: String, arguments: [String]) = CodexProcess.commandSpec(),
        timeout: TimeInterval = 30
    ) throws -> String {
        // File-backed output avoids pipe deadlocks, including on timeout or early exit.
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("codex-plugin-command-\(UUID().uuidString)")
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let stdout = directory.appendingPathComponent("stdout")
        let stderr = directory.appendingPathComponent("stderr")
        try Data().write(to: stdout)
        try Data().write(to: stderr)
        let output = try FileHandle(forWritingTo: stdout)
        let errors = try FileHandle(forWritingTo: stderr)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments + args
        process.currentDirectoryURL = home
        var environment = CodexProcess.environment(codexExecutable: command.executable)
        environment["CODEX_HOME"] = codexHome.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.5
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit() // Rollback cannot race a still-running CLI writer.
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw RuntimeError("codex \(args.joined(separator: " ")) timed out after \(timeout) seconds")
            }
            try checkSize(stdout)
            try checkSize(stderr)
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        try checkSize(stdout)
        try checkSize(stderr)
        let text = String(decoding: try Data(contentsOf: stdout), as: UTF8.self)
        if process.terminationStatus != 0 {
            let errorData = try Data(contentsOf: stderr)
            let detail = String(decoding: Data(text.utf8).suffix(65_536), as: UTF8.self)
                + String(decoding: errorData.suffix(65_536), as: UTF8.self)
            throw RuntimeError("codex \(args.joined(separator: " ")) failed (exit \(process.terminationStatus)):\n\(detail)")
        }
        return text
    }

    private static func checkSize(_ path: URL) throws {
        let size = try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber
        guard (size?.intValue ?? 0) <= 8 * 1_024 * 1_024 else {
            throw RuntimeError("codex plugin output exceeded 8 MiB")
        }
    }
}
