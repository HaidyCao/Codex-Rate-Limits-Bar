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
            state.processStdout(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            state.processStderr(handle.availableData)
        }
        process.terminationHandler = { terminatedProcess in
            if terminatedProcess.terminationStatus != 0 {
                state.fail(RuntimeError("codex app-server exited code=\(terminatedProcess.terminationStatus). stderr=\(state.stderrTail())"))
            }
        }

        try process.run()
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

private final class AppServerCallState: @unchecked Sendable {
    private let lock = NSLock()
    private let labelsById: [Int: String]
    private var pendingIds: Set<Int>
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var stderrLines: [String] = []
    private var didSignal = false

    let semaphore = DispatchSemaphore(value: 0)
    private var results: [String: Any] = [:]
    private var error: Error?

    init(labelsById: [Int: String]) {
        self.labelsById = labelsById
        self.pendingIds = Set(labelsById.keys)
    }

    func processStdout(_ data: Data) {
        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        stdoutBuffer += chunk
        while let newline = stdoutBuffer.firstIndex(of: "\n") {
            let line = String(stdoutBuffer[..<newline])
            stdoutBuffer.removeSubrange(...newline)
            guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = intValue(message["id"]),
                  let label = labelsById[id]
            else {
                continue
            }
            pendingIds.remove(id)
            if let rpcError = message["error"] {
                error = RuntimeError("\(label) failed: \(JSONValue.from(rpcError))")
                signalIfNeeded()
                continue
            }
            results[label] = message["result"] ?? NSNull()
            if pendingIds.isEmpty {
                signalIfNeeded()
            }
        }
        lock.unlock()
    }

    func processStderr(_ data: Data) {
        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        stderrBuffer += chunk
        while let newline = stderrBuffer.firstIndex(of: "\n") {
            let line = String(stderrBuffer[..<newline])
            stderrBuffer.removeSubrange(...newline)
            stderrLines.append(line)
            if stderrLines.count > 50 {
                stderrLines.removeFirst()
            }
        }
        lock.unlock()
    }

    func fail(_ failure: Error) {
        lock.lock()
        if error == nil {
            error = failure
        }
        signalIfNeeded()
        lock.unlock()
    }

    func stderrTail() -> String {
        lock.lock()
        defer { lock.unlock() }
        return stderrLines.suffix(50).joined(separator: "\n")
    }

    func completion() -> (results: [String: Any], error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (results, error)
    }

    private func signalIfNeeded() {
        if !didSignal {
            didSignal = true
            semaphore.signal()
        }
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
