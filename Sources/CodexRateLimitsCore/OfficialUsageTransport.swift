import Darwin
import Foundation

enum OfficialUsageTransport {
    private static let clientName = "codex-rate-limits-bar"
    private static let clientTitle = "Codex Rate Limits Bar"
    private static let clientVersion = "0.1.0"
    static func callCodexAppServer(methods: [String], codexHome: String? = nil, timeout: TimeInterval = 12) throws -> [String: Any] {
        try RefreshWork.check()
        let spec = CodexProcess.commandSpec()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments + ["app-server", "--stdio"]
        process.environment = CodexProcess.environment(codexExecutable: spec.executable)
        if let codexHome { process.environment?["CODEX_HOME"] = codexHome }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        var id = 1
        var labelsById: [Int: String] = [:]
        var requests: [Data] = []
        func enqueue(label: String, method: String, params: [String: Any]? = nil) throws {
            let requestId = id
            id += 1
            labelsById[requestId] = label
            var request: [String: Any] = ["jsonrpc": "2.0", "id": requestId, "method": method]
            if let params {
                request["params"] = params
            }
            let data = try JSONSerialization.data(withJSONObject: request)
            requests.append(data + Data("\n".utf8))
        }

        try enqueue(label: "initialize", method: "initialize", params: [
            "clientInfo": [
                "name": clientName,
                "title": clientTitle,
                "version": clientVersion,
            ],
            "capabilities": [:],
        ])
        for method in methods {
            try enqueue(label: method, method: method, params: method == "account/read" ? ["refreshToken": false] : nil)
        }

        let state = AppServerCallState(labelsById: labelsById)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            state.processStdout(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            state.processStderr(data)
        }
        process.terminationHandler = { terminatedProcess in
            if terminatedProcess.terminationStatus != 0 {
                state.fail(RuntimeError("codex app-server exited code=\(terminatedProcess.terminationStatus). stderr=\(state.stderrTail())"))
            }
        }

        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            try? stdin.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let exitDeadline = Date().addingTimeInterval(0.5)
                while process.isRunning && Date() < exitDeadline { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
        try process.run()
        for request in requests {
            try stdin.fileHandleForWriting.write(contentsOf: request)
        }

        if try !RefreshWork.wait(state.semaphore, timeout: timeout) {
            state.fail(RuntimeError("Timed out waiting for codex app-server response. stderr=\(state.stderrTail())"))
        }
        let completion = state.completion()
        if let error = completion.error {
            throw error
        }
        let results = completion.results
        for method in methods where results[method] == nil {
            throw RuntimeError("codex app-server did not return \(method)")
        }
        return results
    }

    static func fetchData(_ request: URLRequest) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let state = URLFetchState()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                state.complete(.failure(error))
            } else {
                state.complete(.success((data ?? Data(), response!)))
            }
            semaphore.signal()
        }
        task.resume()
        defer { task.cancel() }
        if try !RefreshWork.wait(semaphore, timeout: request.timeoutInterval) {
            throw RuntimeError("Timed out waiting for ChatGPT reset credit response")
        }
        guard let result = state.result() else {
            throw RuntimeError("ChatGPT reset credit response was empty")
        }
        let (data, response) = try result.get()
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RuntimeError("ChatGPT backend returned HTTP \(http.statusCode)")
        }
        return data
    }

}

private final class URLFetchState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<(Data, URLResponse), Error>?

    func complete(_ result: Result<(Data, URLResponse), Error>) {
        lock.lock()
        storedResult = result
        lock.unlock()
    }

    func result() -> Result<(Data, URLResponse), Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storedResult
    }
}
