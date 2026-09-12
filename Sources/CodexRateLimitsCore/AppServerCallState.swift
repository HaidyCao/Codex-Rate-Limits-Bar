import Foundation

/// FileHandle callbacks can split JSON anywhere, including inside a UTF-8
/// scalar. Frame stdout as bytes; decode only complete messages.
final class AppServerCallState: @unchecked Sendable {
    private let lock = NSLock()
    private let labelsById: [Int: String]
    private let maximumLineBytes: Int
    private let maximumStderrBytes: Int
    private var pendingIds: Set<Int>
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var didSignal = false
    private var results: [String: Any] = [:]
    private var error: Error?

    let semaphore = DispatchSemaphore(value: 0)

    init(labelsById: [Int: String], maximumLineBytes: Int = 8 * 1_024 * 1_024,
         maximumStderrBytes: Int = 64 * 1_024) {
        precondition(maximumLineBytes > 0 && maximumStderrBytes > 0)
        self.labelsById = labelsById
        self.pendingIds = Set(labelsById.keys)
        self.maximumLineBytes = maximumLineBytes
        self.maximumStderrBytes = maximumStderrBytes
    }

    func processStdout(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !didSignal else { return }
        if data.isEmpty {
            // A final JSON message need not end in LF. EOF cannot supply any
            // missing responses, so report it immediately instead of timing out.
            if !stdoutBuffer.isEmpty { consumeLine(stdoutBuffer) }
            stdoutBuffer.removeAll(keepingCapacity: false)
            if !didSignal {
                let missing = pendingIds.compactMap { labelsById[$0] }.sorted().joined(separator: ", ")
                failLocked(RuntimeError("codex app-server stdout ended before returning \(missing). stderr=\(stderrTailLocked())"))
            }
            return
        }

        var start = data.startIndex
        while start < data.endIndex && !didSignal {
            let newline = data[start...].firstIndex(of: 0x0A)
            let end = newline ?? data.endIndex
            let segment = data[start..<end]
            guard segment.count <= maximumLineBytes - stdoutBuffer.count else {
                failLocked(RuntimeError("codex app-server stdout line exceeded \(maximumLineBytes) bytes."))
                return
            }
            stdoutBuffer.append(contentsOf: segment)
            guard let newline else { return }
            consumeLine(stdoutBuffer)
            stdoutBuffer.removeAll(keepingCapacity: false)
            start = data.index(after: newline)
        }
    }

    private func consumeLine(_ line: Data) {
        // Preserve tolerance for empty lines, startup text and notifications.
        // Invalid UTF-8 affects this line only, never another frame in the chunk.
        guard String(data: line, encoding: .utf8) != nil,
              let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = intValue(message["id"]), pendingIds.contains(id),
              let label = labelsById[id] else { return }
        pendingIds.remove(id)
        if let rpcError = message["error"] {
            failLocked(RuntimeError("\(label) failed: \(JSONValue.from(rpcError))"))
        } else {
            results[label] = message["result"] ?? NSNull()
            if pendingIds.isEmpty { signalIfNeeded() }
        }
    }

    func processStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if data.count >= maximumStderrBytes {
            stderrBuffer = Data()
            stderrBuffer.append(contentsOf: data.suffix(maximumStderrBytes))
        } else {
            let overflow = stderrBuffer.count - (maximumStderrBytes - data.count)
            if overflow > 0 { stderrBuffer.removeFirst(overflow) }
            stderrBuffer.append(data)
        }
    }

    func fail(_ failure: Error) {
        lock.lock()
        defer { lock.unlock() }
        failLocked(failure)
    }

    private func failLocked(_ failure: Error) {
        guard !didSignal else { return }
        error = failure
        stdoutBuffer.removeAll(keepingCapacity: false)
        signalIfNeeded()
    }

    func stderrTail() -> String {
        lock.lock()
        defer { lock.unlock() }
        return stderrTailLocked()
    }

    private func stderrTailLocked() -> String {
        // Stderr is diagnostic text, so invalid bytes or a truncated prefix may
        // use replacement characters. Keep the final unterminated line too.
        String(decoding: stderrBuffer, as: UTF8.self)
            .split(whereSeparator: \.isNewline).suffix(50).joined(separator: "\n")
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
