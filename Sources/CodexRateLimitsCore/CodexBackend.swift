import Darwin
import Foundation

public enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    static func from(_ value: Any?) -> JSONValue {
        guard let value, !(value is NSNull) else { return .null }
        if let value = value as? String { return .string(value) }
        if let value = value as? Bool { return .bool(value) }
        if let value = value as? Int { return .number(Double(value)) }
        if let value = value as? Int64 { return .number(Double(value)) }
        if let value = value as? Double { return .number(value) }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        }
        if let value = value as? [Any] { return .array(value.map { JSONValue.from($0) }) }
        if let value = value as? [String: Any] {
            return .object(value.mapValues { JSONValue.from($0) })
        }
        return .string(String(describing: value))
    }
}

public struct AccountUsageSnapshot: Codable {
    public let fetchedAtIso: String
    public let usage: JSONValue
}

private struct TokenUsage: Codable {
    var inputTokens: Int64 = 0
    var cachedInputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var reasoningOutputTokens: Int64 = 0
    var totalTokens: Int64 = 0

    static func from(_ value: Any?) -> TokenUsage? {
        guard let object = value as? [String: Any] else { return nil }
        return TokenUsage(
            inputTokens: int64Value(object["input_tokens"]),
            cachedInputTokens: int64Value(object["cached_input_tokens"]),
            outputTokens: int64Value(object["output_tokens"]),
            reasoningOutputTokens: int64Value(object["reasoning_output_tokens"]),
            totalTokens: int64Value(object["total_tokens"])
        )
    }

    mutating func add(_ other: TokenUsage) {
        inputTokens += other.inputTokens
        cachedInputTokens += other.cachedInputTokens
        outputTokens += other.outputTokens
        reasoningOutputTokens += other.reasoningOutputTokens
        totalTokens += other.totalTokens
    }
}

private func stringValue(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }
    if let value = value as? String { return value }
    return String(describing: value)
}

private func intValue(_ value: Any?) -> Int? {
    guard let value, !(value is NSNull) else { return nil }
    if let value = value as? Int { return value }
    if let value = value as? Int64 { return Int(value) }
    if let value = value as? Double { return Int(value) }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
}

private func int64Value(_ value: Any?) -> Int64 {
    guard let value, !(value is NSNull) else { return 0 }
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    if let value = value as? Double { return Int64(value) }
    if let value = value as? NSNumber { return value.int64Value }
    if let value = value as? String { return Int64(value) ?? 0 }
    return 0
}

private func boolValue(_ value: Any?) -> Bool {
    guard let value, !(value is NSNull) else { return false }
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String { return value == "true" }
    return false
}

private func dictionaryValue(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

private func arrayValue(_ value: Any?) -> [Any] {
    value as? [Any] ?? []
}

private func isoNow() -> String {
    ISO8601DateFormatter().string(from: Date())
}

private func isoFromEpochSeconds(_ seconds: Int?) -> String? {
    guard let seconds else { return nil }
    return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
}

private func parseIsoDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) {
        return date
    }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: value)
}

private func errorMessage(_ error: Error) -> String {
    error.localizedDescription
}

private func prettyJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return String(data: try encoder.encode(value), encoding: .utf8) ?? "{}"
}

private func writeJSON<T: Encodable>(_ value: T) throws {
    print(try prettyJSON(value))
}

private func appendSharedLog(_ message: String) {
    let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Logs")
        .appendingPathComponent("Codex Rate Limits Bar.log")
    let timestamp = ISO8601DateFormatter().string(from: Date())
    guard let data = "\(timestamp) \(message)\n".data(using: .utf8) else { return }

    do {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: logURL.path) {
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: logURL, options: .atomic)
        }
    } catch {
        // Logging must never break refresh or CLI output.
    }
}

private func nativeCodexCandidates() -> [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let packageVariants: [(package: String, triple: String)] = [
        ("@openai/codex-darwin-arm64", "aarch64-apple-darwin"),
        ("@openai/codex-darwin-x64", "x86_64-apple-darwin"),
    ]
    var roots: [URL] = []
    let nvmVersions = home
        .appendingPathComponent(".nvm")
        .appendingPathComponent("versions")
        .appendingPathComponent("node")
    if let versions = try? FileManager.default.contentsOfDirectory(at: nvmVersions, includingPropertiesForKeys: nil) {
        roots.append(contentsOf: versions.map {
            $0.appendingPathComponent("lib")
                .appendingPathComponent("node_modules")
                .appendingPathComponent("@openai")
                .appendingPathComponent("codex")
        })
    }
    roots.append(contentsOf: [
        URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/@openai/codex"),
        URL(fileURLWithPath: "/usr/local/lib/node_modules/@openai/codex"),
    ])

    return roots.flatMap { root in
        packageVariants.map { variant in
            root.appendingPathComponent("node_modules")
                .appendingPathComponent(variant.package)
                .appendingPathComponent("vendor")
                .appendingPathComponent(variant.triple)
                .appendingPathComponent("bin")
                .appendingPathComponent("codex")
                .path
        }
    }
}

private func codexManagedEnvironment(for executable: String) -> [String: String] {
    let marker = "/node_modules/@openai/codex/node_modules/"
    guard let range = executable.range(of: marker) else {
        return [:]
    }
    let packageRoot = String(executable[..<range.lowerBound]) + "/node_modules/@openai/codex"
    return [
        "CODEX_MANAGED_BY_NPM": "1",
        "CODEX_MANAGED_PACKAGE_ROOT": packageRoot,
    ]
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
    var results: [String: Any] = [:]
    var error: Error?

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

private final class PipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

public enum CodexBackend {
    private static let clientName = "codex-rate-limits-bar"
    private static let clientTitle = "Codex Rate Limits Bar"
    private static let clientVersion = "0.1.0"
    private static let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    private static let localUsageScanner = LocalUsageScanner()

    public static func readRateLimits() throws -> RateLimitPayload {
        let results = try callCodexAppServer(methods: ["account/rateLimits/read"])
        guard let response = dictionaryValue(results["account/rateLimits/read"]) else {
            throw RuntimeError("account/rateLimits/read returned invalid payload")
        }
        return normalizeRateLimitResponse(response)
    }

    public static func readTokenUsage() throws -> AccountUsageSnapshot {
        let results = try callCodexAppServer(methods: ["account/usage/read"])
        return AccountUsageSnapshot(
            fetchedAtIso: isoNow(),
            usage: JSONValue.from(results["account/usage/read"])
        )
    }

    public static func readCombined() throws -> RateLimitPayload {
        let results = try callCodexAppServer(methods: ["account/rateLimits/read", "account/usage/read"])
        guard let response = dictionaryValue(results["account/rateLimits/read"]) else {
            throw RuntimeError("account/rateLimits/read returned invalid payload")
        }
        let payload = normalizeRateLimitResponse(response)
        return RateLimitPayload(
            fetchedAtIso: payload.fetchedAtIso,
            rateLimits: payload.rateLimits,
            rateLimitsByLimitId: payload.rateLimitsByLimitId,
            display: payload.display,
            resetCredits: nil,
            localUsage: nil,
            rateLimitError: nil,
            localUsageError: nil,
            usage: JSONValue.from(results["account/usage/read"])
        )
    }

    public static func readResetCredits(soft: Bool = false) throws -> ResetCreditsSnapshot {
        do {
            let tokens = try readCodexAuthTokens()
            var request = URLRequest(url: resetCreditsURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 12
            request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
            request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
            if let accountID = tokens.accountID {
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
            }

            let data = try fetchData(request)
            let object = try JSONSerialization.jsonObject(with: data)
            return normalizeResetCreditsResponse(dictionaryValue(object) ?? [:])
        } catch {
            if soft {
                return emptyResetCreditsSnapshot(error)
            }
            throw error
        }
    }

    public static func readStatus() -> RateLimitPayload {
        let ratePayload: RateLimitPayload
        do {
            ratePayload = try readRateLimits()
        } catch {
            ratePayload = emptyRateLimitSnapshot(error)
        }

        let resetCredits = (try? readResetCredits(soft: true)) ?? emptyResetCreditsSnapshot(RuntimeError("reset credits unavailable"))
        let localUsage: LocalUsageSnapshot
        let localUsageError: String?
        do {
            localUsage = try readLocalTokenUsage()
            localUsageError = nil
        } catch {
            localUsage = emptyLocalUsageSnapshot(error)
            localUsageError = errorMessage(error)
        }

        return RateLimitPayload(
            fetchedAtIso: ratePayload.fetchedAtIso,
            rateLimits: ratePayload.rateLimits,
            rateLimitsByLimitId: ratePayload.rateLimitsByLimitId,
            display: ratePayload.display,
            resetCredits: resetCredits,
            localUsage: localUsage,
            rateLimitError: ratePayload.rateLimitError,
            localUsageError: localUsageError,
            usage: nil
        )
    }

    public static func readLocalTokenUsage() throws -> LocalUsageSnapshot {
        try localUsageScanner.snapshot()
    }

    private static func localUsageRootURLs() -> [URL] {
        let sessionsRoot = ProcessInfo.processInfo.environment["CODEX_SESSIONS_DIR"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex")
                .appendingPathComponent("sessions")
                .path
        let sessionsURL = URL(fileURLWithPath: sessionsRoot).standardizedFileURL

        guard ProcessInfo.processInfo.environment["CODEX_SESSIONS_DIR"] == nil else {
            return [sessionsURL]
        }

        let archivedURL = sessionsURL
            .deletingLastPathComponent()
            .appendingPathComponent("archived_sessions")
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: archivedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              archivedURL.path != sessionsURL.path
        else {
            return [sessionsURL]
        }

        return [sessionsURL, archivedURL]
    }

    private static func localUsageSourceDescription(rootURLs: [URL]) -> String {
        rootURLs.map(\.path).joined(separator: ",")
    }

    final class LocalUsageScanner: @unchecked Sendable {
        private static let readChunkSize = 4 * 1_024 * 1_024
        private static let sessionMetaMarker = Data("\"type\":\"session_meta\"".utf8)
        private static let tokenCountMarker = Data("\"type\":\"token_count\"".utf8)

        private let lock = NSLock()
        private let rootURLsProvider: () -> [URL]
        private let nowProvider: () -> Date
        private let calendarProvider: () -> Calendar
        private let cacheFileURL: URL?
        private var didLoadPersistentCache = false
        private var cache: LocalUsageScanCache?

        init() {
            rootURLsProvider = CodexBackend.localUsageRootURLs
            nowProvider = Date.init
            calendarProvider = { .current }
            if ProcessInfo.processInfo.environment["CODEX_SESSIONS_DIR"] == nil {
                cacheFileURL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library")
                    .appendingPathComponent("Application Support")
                    .appendingPathComponent("Codex Rate Limits Bar")
                    .appendingPathComponent("local-usage-cache.json")
            } else {
                cacheFileURL = nil
            }
        }

        init(rootURLs: [URL], calendar: Calendar, now: @escaping () -> Date, cacheFileURL: URL? = nil) {
            rootURLsProvider = { rootURLs }
            nowProvider = now
            calendarProvider = { calendar }
            self.cacheFileURL = cacheFileURL
        }

        init(
            rootURLs: [URL],
            calendarProvider: @escaping () -> Calendar,
            now: @escaping () -> Date,
            cacheFileURL: URL? = nil
        ) {
            rootURLsProvider = { rootURLs }
            nowProvider = now
            self.calendarProvider = calendarProvider
            self.cacheFileURL = cacheFileURL
        }

        func snapshot() throws -> LocalUsageSnapshot {
            lock.lock()
            defer { lock.unlock() }
            return try scanLocked()
        }

        private func scanLocked() throws -> LocalUsageSnapshot {
            let startedAt = Date()
            let now = nowProvider()
            let calendar = calendarProvider()
            let dayStart = calendar.startOfDay(for: now)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now
            let localDate = CodexBackend.localDateString(now, timeZone: calendar.timeZone)
            let timeZone = calendar.timeZone.identifier
            let rootURLs = rootURLsProvider()
            let source = CodexBackend.localUsageSourceDescription(rootURLs: rootURLs)
            loadPersistentCacheIfNeeded()

            let canReuseBaseline = cache?.source == source && cache?.timeZone == timeZone
            let isColdScan: Bool
            var cacheChanged = false
            if !canReuseBaseline {
                cache = LocalUsageScanCache(
                    source: source,
                    localDate: localDate,
                    timeZone: timeZone,
                    dayStart: dayStart,
                    dayEnd: dayEnd
                )
                isColdScan = true
                cacheChanged = true
            } else if cache?.localDate != localDate, let previous = cache {
                cache = LocalUsageScanCache(
                    source: source,
                    localDate: localDate,
                    timeZone: timeZone,
                    dayStart: dayStart,
                    dayEnd: dayEnd,
                    files: previous.files.mapValues { $0.resetForNewDay() }
                )
                isColdScan = false
                cacheChanged = true
            } else {
                cache?.dayStart = dayStart
                cache?.dayEnd = dayEnd
                isColdScan = false
            }

            guard var cache else {
                throw RuntimeError("local usage cache unavailable")
            }

            let files = CodexBackend.deduplicatedJsonlFileInfos(rootURLs
                .flatMap { CodexBackend.walkJsonlFileInfos(root: $0, dayStart: dayStart) }
            )
            var stats = LocalUsageScanStats()
            stats.filesScanned = files.count

            let livePaths = Set(files.map(\.url.path))
            let previousFileCount = cache.files.count
            cache.files = cache.files.filter { livePaths.contains($0.key) }
            cacheChanged = cacheChanged || cache.files.count != previousFileCount

            for file in files {
                cacheChanged = scan(file, cache: &cache, stats: &stats) || cacheChanged
            }

            self.cache = cache
            if cacheChanged {
                persist(cache)
            }
            let snapshot = makeSnapshot(cache: cache, filesScanned: files.count, now: now)
            stats.durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            log(stats: stats, coldScan: isColdScan)
            return snapshot
        }

        private func loadPersistentCacheIfNeeded() {
            guard !didLoadPersistentCache else { return }
            didLoadPersistentCache = true
            guard let cacheFileURL,
                  let data = try? Data(contentsOf: cacheFileURL)
            else {
                return
            }

            do {
                let document = try JSONDecoder().decode(LocalUsageCacheDocument.self, from: data)
                if document.version == LocalUsageCacheDocument.currentVersion {
                    cache = document.cache
                }
            } catch {
                appendSharedLog("local usage cache ignored: \(errorMessage(error))")
            }
        }

        private func persist(_ cache: LocalUsageScanCache) {
            guard let cacheFileURL else { return }
            do {
                try FileManager.default.createDirectory(
                    at: cacheFileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let document = LocalUsageCacheDocument(cache: cache)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(document).write(to: cacheFileURL, options: .atomic)
            } catch {
                appendSharedLog("local usage cache write failed: \(errorMessage(error))")
            }
        }

        private func scan(
            _ file: JsonlFileInfo,
            cache: inout LocalUsageScanCache,
            stats: inout LocalUsageScanStats
        ) -> Bool {
            let path = file.url.path
            let hadState = cache.files[path] != nil
            var state = cache.files[path] ?? LocalUsageFileState()
            var changed = !hadState
            if !hadState {
                stats.fullRescanFiles += 1
            }
            if file.size < state.offset {
                state = LocalUsageFileState()
                stats.fullRescanFiles += 1
                changed = true
            }

            defer {
                state.size = max(file.size, state.offset)
                state.modifiedAt = file.modifiedAt
                cache.files[path] = state
            }

            guard file.size > state.offset else {
                return changed
            }

            do {
                let handle = try FileHandle(forReadingFrom: file.url)
                defer { try? handle.close() }
                try handle.seek(toOffset: state.offset)
                var remaining = file.size - state.offset
                while remaining > 0 {
                    let count = min(Self.readChunkSize, Int(remaining))
                    guard let data = try handle.read(upToCount: count), !data.isEmpty else { break }
                    state.offset += UInt64(data.count)
                    remaining -= UInt64(data.count)
                    stats.bytesRead += UInt64(data.count)
                    process(data: data, state: &state, dayStart: cache.dayStart, dayEnd: cache.dayEnd)
                }
                stats.filesRead += 1
                changed = true
            } catch {
                stats.readFailureCount += 1
                appendSharedLog("local usage scan read failure: \(path): \(errorMessage(error))")
            }
            return changed
        }

        private func process(data: Data, state: inout LocalUsageFileState, dayStart: Date, dayEnd: Date) {
            guard !data.isEmpty else { return }
            let previousPendingCount = state.pendingData.count
            state.pendingData.append(data)

            var lineStart = state.pendingData.startIndex
            var consumedThrough = state.pendingData.startIndex
            var newlineSearchStart = state.pendingData.index(
                state.pendingData.startIndex,
                offsetBy: previousPendingCount
            )
            while let newlineIndex = state.pendingData[newlineSearchStart...].firstIndex(of: 0x0A) {
                let lineData = trimmedLineData(state.pendingData[lineStart..<newlineIndex])
                if isPotentialUsageLine(lineData) {
                    processLine(lineData, state: &state, dayStart: dayStart, dayEnd: dayEnd)
                }
                let nextIndex = state.pendingData.index(after: newlineIndex)
                lineStart = nextIndex
                newlineSearchStart = nextIndex
                consumedThrough = nextIndex
            }

            if consumedThrough > state.pendingData.startIndex {
                state.pendingData.removeSubrange(state.pendingData.startIndex..<consumedThrough)
            }
        }

        private func isPotentialUsageLine(_ data: Data) -> Bool {
            let prefix = data.prefix(1_024)
            if prefix.range(of: Self.sessionMetaMarker) != nil
                || prefix.range(of: Self.tokenCountMarker) != nil
            {
                return true
            }
            let suffix = data.suffix(256)
            return suffix.range(of: Self.sessionMetaMarker) != nil
                || suffix.range(of: Self.tokenCountMarker) != nil
        }

        private func trimmedLineData(_ data: Data) -> Data {
            guard data.last == 0x0D else { return data }
            return data.dropLast()
        }

        private func processLine(_ lineData: Data, state: inout LocalUsageFileState, dayStart: Date, dayEnd: Date) {
            guard !lineData.isEmpty else { return }
            let object: [String: Any]
            do {
                object = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] ?? [:]
            } catch {
                state.parseErrorCount += 1
                return
            }

            if let sessionId = CodexBackend.sessionIdFromMeta(object) {
                if state.primarySessionId == nil {
                    state.primarySessionId = sessionId
                }
                state.activeSessionId = sessionId
                return
            }

            guard stringValue(object["type"]) == "event_msg",
                  let payload = dictionaryValue(object["payload"]),
                  stringValue(payload["type"]) == "token_count",
                  let info = dictionaryValue(payload["info"]),
                  let currentTotalUsage = TokenUsage.from(info["total_token_usage"])
            else {
                return
            }

            let timestamp = parseIsoDate(stringValue(object["timestamp"]))
            let isToday = timestamp.map { $0 >= dayStart && $0 < dayEnd } ?? false
            if isToday {
                let isImportedForkEvent = state.primarySessionId != nil
                    && state.activeSessionId != nil
                    && state.activeSessionId != state.primarySessionId
                if isImportedForkEvent {
                    state.importedEventCount += 1
                } else {
                    let sameSession = state.previousUsageSessionId == state.activeSessionId
                    let baseline = sameSession ? state.previousTotalUsage : state.previousObservedTotalUsage
                    let regressed = sameSession && CodexBackend.usageRegressed(baseline, currentTotalUsage)
                    if let delta = CodexBackend.positiveDelta(baseline, currentTotalUsage, sameSession: sameSession) {
                        state.totals.add(delta)
                    } else {
                        state.duplicateEventCount += 1
                        if regressed {
                            state.regressionEventCount += 1
                        }
                    }
                    state.eventCount += 1
                    state.lastEventAtIso = stringValue(object["timestamp"])
                }
            }

            let sameSession = state.previousUsageSessionId == state.activeSessionId
            if sameSession || !CodexBackend.usageRegressed(state.previousTotalUsage, currentTotalUsage) {
                state.previousTotalUsage = CodexBackend.maxTokenUsage(state.previousTotalUsage, currentTotalUsage)
            } else {
                state.previousTotalUsage = currentTotalUsage
            }
            state.previousUsageSessionId = state.activeSessionId
            state.previousObservedTotalUsage = currentTotalUsage
        }

        private func makeSnapshot(cache: LocalUsageScanCache, filesScanned: Int, now: Date) -> LocalUsageSnapshot {
            var totals = TokenUsage()
            var topFiles: [LocalUsageTopFile] = []
            var eventCount = 0
            var duplicateEventCount = 0
            var importedEventCount = 0
            var regressionEventCount = 0
            var filesWithEvents = 0
            var parseErrorCount = 0

            for (path, state) in cache.files {
                totals.add(state.totals)
                eventCount += state.eventCount
                duplicateEventCount += state.duplicateEventCount
                importedEventCount += state.importedEventCount
                regressionEventCount += state.regressionEventCount
                parseErrorCount += state.parseErrorCount

                guard state.eventCount > 0 else { continue }
                filesWithEvents += 1
                topFiles.append(LocalUsageTopFile(
                    file: path,
                    eventCount: state.eventCount,
                    duplicateEventCount: state.duplicateEventCount,
                    importedEventCount: state.importedEventCount,
                    regressionEventCount: state.regressionEventCount,
                    primarySessionId: state.primarySessionId,
                    totalTokens: state.totals.totalTokens,
                    lastEventAtIso: state.lastEventAtIso
                ))
            }

            let cacheHitPercent = totals.inputTokens > 0
                ? max(0, min(100, (Double(totals.cachedInputTokens) / Double(totals.inputTokens)) * 100))
                : nil
            topFiles.sort { $0.totalTokens > $1.totalTokens }

            return LocalUsageSnapshot(
                fetchedAtIso: ISO8601DateFormatter().string(from: now),
                source: cache.source,
                timezone: cache.timeZone,
                localDate: cache.localDate,
                inputTokens: totals.inputTokens,
                cachedInputTokens: totals.cachedInputTokens,
                outputTokens: totals.outputTokens,
                reasoningOutputTokens: totals.reasoningOutputTokens,
                totalTokens: totals.totalTokens,
                cacheHitPercent: cacheHitPercent,
                eventCount: eventCount,
                duplicateEventCount: duplicateEventCount,
                importedEventCount: importedEventCount,
                regressionEventCount: regressionEventCount,
                filesScanned: filesScanned,
                filesWithEvents: filesWithEvents,
                parseErrorCount: parseErrorCount,
                error: nil,
                topFiles: Array(topFiles.prefix(8)),
                display: LocalUsageDisplay(
                    consumptionLabel: AppText.consumption(TokenAmountFormatter.compact(totals.totalTokens)),
                    cacheHitLabel: AppText.cacheHit(CodexBackend.formatCacheHitPercent(cacheHitPercent))
                )
            )
        }

        private func log(stats: LocalUsageScanStats, coldScan: Bool) {
            guard stats.bytesRead > 0 || stats.fullRescanFiles > 0 || stats.readFailureCount > 0 || stats.durationMs > 1000 else {
                return
            }
            appendSharedLog("local usage scan files=\(stats.filesScanned) readFiles=\(stats.filesRead) bytes=\(stats.bytesRead) durationMs=\(stats.durationMs) fullRescanFiles=\(stats.fullRescanFiles) cold=\(coldScan) readFailures=\(stats.readFailureCount)")
        }
    }

    private struct LocalUsageCacheDocument: Codable {
        static let currentVersion = 1

        var version = currentVersion
        let cache: LocalUsageScanCache
    }

    private struct LocalUsageScanCache: Codable {
        let source: String
        let localDate: String
        let timeZone: String
        var dayStart: Date
        var dayEnd: Date
        var files: [String: LocalUsageFileState] = [:]
    }

    private struct LocalUsageFileState: Codable {
        var offset: UInt64 = 0
        var size: UInt64 = 0
        var modifiedAt: Date?
        var pendingData = Data()
        var previousTotalUsage: TokenUsage?
        var previousObservedTotalUsage: TokenUsage?
        var previousUsageSessionId: String?
        var primarySessionId: String?
        var activeSessionId: String?
        var totals = TokenUsage()
        var eventCount = 0
        var duplicateEventCount = 0
        var importedEventCount = 0
        var regressionEventCount = 0
        var parseErrorCount = 0
        var lastEventAtIso: String?

        func resetForNewDay() -> LocalUsageFileState {
            var state = self
            state.totals = TokenUsage()
            state.eventCount = 0
            state.duplicateEventCount = 0
            state.importedEventCount = 0
            state.regressionEventCount = 0
            state.parseErrorCount = 0
            state.lastEventAtIso = nil
            return state
        }
    }

    private struct LocalUsageScanStats {
        var filesScanned = 0
        var filesRead = 0
        var bytesRead: UInt64 = 0
        var fullRescanFiles = 0
        var readFailureCount = 0
        var durationMs = 0
    }

    private static func normalizeRateLimitResponse(_ response: [String: Any]) -> RateLimitPayload {
        let rateLimits = normalizeSnapshot(dictionaryValue(response["rateLimits"]))
        var byLimitId: [String: RateLimitSnapshot] = [:]
        for (limitId, value) in dictionaryValue(response["rateLimitsByLimitId"]) ?? [:] {
            byLimitId[limitId] = normalizeSnapshot(dictionaryValue(value))
        }
        let weekly = rateLimits?.weeklyWindow
        let display = RateLimitDisplay(
            primaryLabel: weekly.map { "W \($0.remainingPercent)%" } ?? "W --",
            secondaryLabel: nil,
            primaryRemainingPercent: weekly?.remainingPercent,
            secondaryRemainingPercent: nil
        )
        return RateLimitPayload(
            fetchedAtIso: isoNow(),
            rateLimits: rateLimits,
            rateLimitsByLimitId: byLimitId.isEmpty ? nil : byLimitId,
            display: display,
            resetCredits: nil,
            localUsage: nil,
            rateLimitError: nil,
            localUsageError: nil,
            usage: nil
        )
    }

    private static func normalizeSnapshot(_ snapshot: [String: Any]?) -> RateLimitSnapshot? {
        guard let snapshot else { return nil }
        return RateLimitSnapshot(
            limitId: stringValue(snapshot["limitId"]),
            limitName: stringValue(snapshot["limitName"]),
            planType: stringValue(snapshot["planType"]),
            rateLimitReachedType: stringValue(snapshot["rateLimitReachedType"]),
            primary: normalizeWindow(dictionaryValue(snapshot["primary"])),
            secondary: normalizeWindow(dictionaryValue(snapshot["secondary"])),
            credits: normalizeCredits(dictionaryValue(snapshot["credits"])),
            individualLimit: snapshot.keys.contains("individualLimit") ? JSONValue.from(snapshot["individualLimit"]) : nil
        )
    }

    private static func normalizeWindow(_ window: [String: Any]?) -> RateLimitWindow? {
        guard let window else { return nil }
        let usedPercent = intValue(window["usedPercent"]) ?? 0
        let resetsAt = intValue(window["resetsAt"])
        return RateLimitWindow(
            usedPercent: usedPercent,
            remainingPercent: max(0, 100 - usedPercent),
            windowDurationMins: intValue(window["windowDurationMins"]),
            resetsAt: resetsAt,
            resetsAtIso: isoFromEpochSeconds(resetsAt)
        )
    }

    private static func normalizeCredits(_ credits: [String: Any]?) -> CreditsSnapshot? {
        guard let credits else { return nil }
        return CreditsSnapshot(
            hasCredits: boolValue(credits["hasCredits"]),
            unlimited: boolValue(credits["unlimited"]),
            balance: stringValue(credits["balance"])
        )
    }

    private static func normalizeResetCreditsResponse(_ response: [String: Any]) -> ResetCreditsSnapshot {
        var credits = arrayValue(response["credits"])
            .compactMap { normalizeResetCredit(dictionaryValue($0)) }
        credits.sort { resetCreditSortKey($0) < resetCreditSortKey($1) }

        let fallbackAvailableCount = credits.filter { $0.status == "available" }.count
        let availableCount = intValue(response["available_count"]) ?? fallbackAvailableCount
        let firstTypeLabel = credits.first?.typeLabel ?? AppText.resetCreditsCategory
        let visibleSource = credits.contains { $0.status == "available" }
            ? credits.filter { $0.status == "available" }
            : credits
        let detailLabels = Array(visibleSource.prefix(4)).enumerated().map { index, credit in
            AppText.resetCreditDetail(
                index: index + 1,
                status: credit.statusLabel,
                expiresAt: credit.expiresAtShortLabel
            )
        }

        return ResetCreditsSnapshot(
            fetchedAtIso: isoNow(),
            availableCount: availableCount,
            credits: credits,
            error: nil,
            display: ResetCreditsDisplay(
                summaryLabel: AppText.availableCount(availableCount),
                categoryLabel: firstTypeLabel,
                detailLabels: detailLabels
            )
        )
    }

    private static func normalizeResetCredit(_ credit: [String: Any]?) -> ResetCreditItem? {
        guard let credit else { return nil }
        let resetType = stringValue(credit["reset_type"]) ?? stringValue(credit["type"]) ?? "unknown"
        let status = stringValue(credit["status"])
        let createdAtIso = isoString(credit["created_at"] ?? credit["granted_at"])
        let expiresAtIso = isoString(credit["expires_at"])
        return ResetCreditItem(
            id: stringValue(credit["id"]),
            resetType: resetType,
            typeLabel: resetCreditTypeLabel(resetType),
            status: status,
            statusLabel: resetCreditStatusLabel(status),
            createdAtIso: createdAtIso,
            expiresAtIso: expiresAtIso,
            createdAtLabel: AppText.resetDateTime(createdAtIso, short: false),
            expiresAtLabel: AppText.resetDateTime(expiresAtIso, short: false),
            createdAtShortLabel: AppText.resetDateTime(createdAtIso, short: true),
            expiresAtShortLabel: AppText.resetDateTime(expiresAtIso, short: true)
        )
    }

    private static func emptyRateLimitSnapshot(_ error: Error) -> RateLimitPayload {
        RateLimitPayload(
            fetchedAtIso: isoNow(),
            rateLimits: nil,
            rateLimitsByLimitId: nil,
            display: RateLimitDisplay(
                primaryLabel: "W --",
                secondaryLabel: nil,
                primaryRemainingPercent: nil,
                secondaryRemainingPercent: nil
            ),
            resetCredits: nil,
            localUsage: nil,
            rateLimitError: errorMessage(error),
            localUsageError: nil,
            usage: nil
        )
    }

    private static func emptyResetCreditsSnapshot(_ error: Error) -> ResetCreditsSnapshot {
        ResetCreditsSnapshot(
            fetchedAtIso: isoNow(),
            availableCount: nil,
            credits: [],
            error: errorMessage(error),
            display: ResetCreditsDisplay(
                summaryLabel: AppText.availableCount(nil),
                categoryLabel: AppText.resetCreditsCategory,
                detailLabels: [AppText.resetCreditsUnavailable]
            )
        )
    }

    private static func emptyLocalUsageSnapshot(_ error: Error) -> LocalUsageSnapshot {
        let now = Date()
        let source = localUsageSourceDescription(rootURLs: localUsageRootURLs())
        return LocalUsageSnapshot(
            fetchedAtIso: ISO8601DateFormatter().string(from: now),
            source: source,
            timezone: TimeZone.current.identifier,
            localDate: localDateString(now, timeZone: .current),
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            totalTokens: 0,
            cacheHitPercent: nil,
            eventCount: 0,
            duplicateEventCount: 0,
            importedEventCount: 0,
            regressionEventCount: 0,
            filesScanned: 0,
            filesWithEvents: 0,
            parseErrorCount: 0,
            error: errorMessage(error),
            topFiles: [],
            display: LocalUsageDisplay(consumptionLabel: AppText.consumption(nil), cacheHitLabel: AppText.cacheHit(nil))
        )
    }

    private static func callCodexAppServer(methods: [String], timeout: TimeInterval = 12) throws -> [String: Any] {
        let spec = codexCommandSpec()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments + ["app-server", "--stdio"]
        process.environment = processEnvironment(codexExecutable: spec.executable)

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
            try enqueue(label: method, method: method)
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
        for request in requests {
            stdin.fileHandleForWriting.write(request)
        }

        if state.semaphore.wait(timeout: .now() + timeout) == .timedOut {
            state.fail(RuntimeError("Timed out waiting for codex app-server response. stderr=\(state.stderrTail())"))
            process.terminate()
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        try? stdin.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
        if let error = state.error {
            throw error
        }
        let results = state.results
        for method in methods where results[method] == nil {
            throw RuntimeError("codex app-server did not return \(method)")
        }
        return results
    }

    private static func codexCommandSpec() -> (executable: String, arguments: [String]) {
        let candidates = ([ProcessInfo.processInfo.environment["CODEX_BIN"]].compactMap { $0 }
            + nativeCodexCandidates()
            + [
                "/Applications/Codex.app/Contents/Resources/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
            ]).filter { !$0.isEmpty }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return (candidate, [])
        }
        return ("/usr/bin/env", ["codex"])
    }

    private static func processEnvironment(codexExecutable: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        let path = [
            "/Applications/Codex.app/Contents/Resources",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            env["PATH"] ?? "",
        ].joined(separator: ":")
        env["PATH"] = path
        env.merge(codexManagedEnvironment(for: codexExecutable)) { _, new in new }
        return env
    }

    private struct CodexAuthTokens {
        let accessToken: String
        let accountID: String?
    }

    private static func readCodexAuthTokens() throws -> CodexAuthTokens {
        let authPath = ProcessInfo.processInfo.environment["CODEX_AUTH_FILE"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex")
                .appendingPathComponent("auth.json")
                .path
        let data = try Data(contentsOf: URL(fileURLWithPath: authPath))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let tokens = dictionaryValue(object["tokens"]) ?? [:]
        guard let accessToken = stringValue(tokens["access_token"]), !accessToken.isEmpty else {
            throw RuntimeError("Codex auth file is missing tokens.access_token. Run codex login again.")
        }
        return CodexAuthTokens(accessToken: accessToken, accountID: stringValue(tokens["account_id"]))
    }

    private static func fetchData(_ request: URLRequest) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let state = URLFetchState()
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                state.complete(.failure(error))
            } else {
                state.complete(.success((data ?? Data(), response!)))
            }
            semaphore.signal()
        }.resume()
        if semaphore.wait(timeout: .now() + request.timeoutInterval) == .timedOut {
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

    private struct JsonlFileInfo {
        let url: URL
        let modifiedAt: Date
        let size: UInt64
    }

    private static func walkJsonlFileInfos(root: URL, dayStart: Date) -> [JsonlFileInfo] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [JsonlFileInfo] = []
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt >= dayStart
            else {
                continue
            }
            files.append(JsonlFileInfo(url: file, modifiedAt: modifiedAt, size: UInt64(values.fileSize ?? 0)))
        }
        return files
    }

    private static func deduplicatedJsonlFileInfos(_ files: [JsonlFileInfo]) -> [JsonlFileInfo] {
        var byFileName: [String: JsonlFileInfo] = [:]
        for file in files {
            let key = file.url.lastPathComponent
            guard let existing = byFileName[key] else {
                byFileName[key] = file
                continue
            }

            if file.size > existing.size
                || (file.size == existing.size && file.url.path < existing.url.path) {
                byFileName[key] = file
            }
        }
        return byFileName.values.sorted { $0.url.path < $1.url.path }
    }

    private static func sessionIdFromMeta(_ event: [String: Any]) -> String? {
        guard stringValue(event["type"]) == "session_meta",
              let payload = dictionaryValue(event["payload"])
        else {
            return nil
        }
        return stringValue(payload["id"]) ?? stringValue(payload["session_id"])
    }

    private static func usageRegressed(_ previous: TokenUsage?, _ current: TokenUsage) -> Bool {
        guard let previous else { return false }
        return current.totalTokens < previous.totalTokens
    }

    private static func maxTokenUsage(_ previous: TokenUsage?, _ current: TokenUsage) -> TokenUsage {
        guard let previous else { return current }
        return TokenUsage(
            inputTokens: max(previous.inputTokens, current.inputTokens),
            cachedInputTokens: max(previous.cachedInputTokens, current.cachedInputTokens),
            outputTokens: max(previous.outputTokens, current.outputTokens),
            reasoningOutputTokens: max(previous.reasoningOutputTokens, current.reasoningOutputTokens),
            totalTokens: max(previous.totalTokens, current.totalTokens)
        )
    }

    private static func positiveDelta(_ previous: TokenUsage?, _ current: TokenUsage, sameSession: Bool) -> TokenUsage? {
        if previous != nil && sameSession && usageRegressed(previous, current) {
            return nil
        }
        let previous = previous ?? TokenUsage()
        let delta = TokenUsage(
            inputTokens: current.inputTokens >= previous.inputTokens ? current.inputTokens - previous.inputTokens : (sameSession ? 0 : current.inputTokens),
            cachedInputTokens: current.cachedInputTokens >= previous.cachedInputTokens ? current.cachedInputTokens - previous.cachedInputTokens : (sameSession ? 0 : current.cachedInputTokens),
            outputTokens: current.outputTokens >= previous.outputTokens ? current.outputTokens - previous.outputTokens : (sameSession ? 0 : current.outputTokens),
            reasoningOutputTokens: current.reasoningOutputTokens >= previous.reasoningOutputTokens ? current.reasoningOutputTokens - previous.reasoningOutputTokens : (sameSession ? 0 : current.reasoningOutputTokens),
            totalTokens: current.totalTokens >= previous.totalTokens ? current.totalTokens - previous.totalTokens : (sameSession ? 0 : current.totalTokens)
        )
        return delta.inputTokens > 0
            || delta.cachedInputTokens > 0
            || delta.outputTokens > 0
            || delta.reasoningOutputTokens > 0
            || delta.totalTokens > 0 ? delta : nil
    }

    private static func localDateString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func formatCacheHitPercent(_ percent: Double?) -> String {
        guard let percent else { return "--" }
        return String(format: "%.1f%%", percent)
    }

    private static func isoString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            let seconds = raw > 10_000_000_000 ? raw / 1000 : raw
            return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
        }
        guard let string = stringValue(value), !string.isEmpty else { return nil }
        return parseIsoDate(string).map { ISO8601DateFormatter().string(from: $0) }
    }

    private static func resetCreditTypeLabel(_ value: String?) -> String {
        AppText.resetCreditTypeLabel(value)
    }

    private static func resetCreditStatusLabel(_ value: String?) -> String {
        AppText.resetCreditStatusLabel(value)
    }

    private static func resetCreditSortKey(_ credit: ResetCreditItem) -> String {
        if credit.status == "available" {
            return "0-\(credit.expiresAtIso ?? "")-\(credit.createdAtIso ?? "")"
        }
        return "1-\(credit.expiresAtIso ?? "")-\(credit.createdAtIso ?? "")"
    }
}

enum CodexMCPServer {
    static func run() {
        let activity = MCPActivity()
        let timer = makeIdleTimer(activity: activity)
        timer?.resume()
        defer { timer?.cancel() }

        while let line = readLine() {
            activity.beginHandling()
            defer { activity.endHandling() }

            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  message.keys.contains("id")
            else {
                continue
            }
            handle(message)
        }
    }

    private static func makeIdleTimer(activity: MCPActivity) -> DispatchSourceTimer? {
        let timeout = idleTimeout()
        guard timeout > 0 else { return nil }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        let timeoutInterval = DispatchTimeInterval.milliseconds(Int(timeout * 1000))
        let repeatSeconds = min(30, max(5, timeout / 4))
        let repeatInterval = DispatchTimeInterval.milliseconds(Int(repeatSeconds * 1000))
        timer.schedule(deadline: .now() + timeoutInterval, repeating: repeatInterval)
        timer.setEventHandler {
            guard activity.shouldExit(timeout: timeout) else { return }
            appendSharedLog("mcp idle exit after \(Int(timeout))s")
            Darwin.exit(0)
        }
        return timer
    }

    private static func idleTimeout() -> TimeInterval {
        guard let raw = ProcessInfo.processInfo.environment["CODEX_MCP_IDLE_TIMEOUT_SECONDS"],
              let value = TimeInterval(raw)
        else {
            return 300
        }
        return max(0, value)
    }

    private final class MCPActivity: @unchecked Sendable {
        private let lock = NSLock()
        private var lastActivity = Date()
        private var activeRequests = 0

        func beginHandling() {
            lock.lock()
            activeRequests += 1
            lastActivity = Date()
            lock.unlock()
        }

        func endHandling() {
            lock.lock()
            activeRequests = max(0, activeRequests - 1)
            lastActivity = Date()
            lock.unlock()
        }

        func shouldExit(timeout: TimeInterval) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return activeRequests == 0 && Date().timeIntervalSince(lastActivity) >= timeout
        }
    }

    private static func handle(_ message: [String: Any]) {
        let id = message["id"] ?? NSNull()
        let method = stringValue(message["method"])
        if method == "initialize" {
            respond(id: id, result: [
                "protocolVersion": dictionaryValue(message["params"]).flatMap { stringValue($0["protocolVersion"]) } ?? "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "codex-usage-monitor", "version": "0.4.0"],
            ])
            return
        }
        if method == "tools/list" {
            respond(id: id, result: ["tools": tools()])
            return
        }
        if method == "tools/call" {
            let params = dictionaryValue(message["params"]) ?? [:]
            let name = stringValue(params["name"]) ?? ""
            do {
                let text: String
                switch name {
                case "get_codex_status":
                    text = try prettyJSON(CodexBackend.readStatus())
                case "get_codex_rate_limits":
                    text = try prettyJSON(CodexBackend.readRateLimits())
                case "get_codex_local_usage":
                    text = try prettyJSON(CodexBackend.readLocalTokenUsage())
                case "get_codex_account_usage":
                    text = try prettyJSON(CodexBackend.readTokenUsage())
                case "get_codex_reset_credits":
                    text = try prettyJSON(CodexBackend.readResetCredits())
                default:
                    respondError(id: id, code: -32602, message: "Unknown tool: \(name)")
                    return
                }
                respond(id: id, result: ["content": [["type": "text", "text": text]]])
            } catch {
                respondError(id: id, code: -32000, message: errorMessage(error))
            }
            return
        }
        if method == "ping" {
            respond(id: id, result: [:])
            return
        }
        respondError(id: id, code: -32601, message: "Method not found: \(method ?? "")")
    }

    private static func emptyInputSchema() -> [String: Any] {
        ["type": "object", "properties": [:], "additionalProperties": false]
    }

    private static func tools() -> [[String: Any]] {
        [
            [
                "name": "get_codex_status",
                "description": "Read the combined Codex rate-limit snapshot and machine-local token usage from Codex Rate Limits Bar.",
                "inputSchema": emptyInputSchema(),
            ],
            [
                "name": "get_codex_rate_limits",
                "description": "Read the current Codex weekly rate-limit snapshot.",
                "inputSchema": emptyInputSchema(),
            ],
            [
                "name": "get_codex_local_usage",
                "description": "Read today's machine-local Codex token usage from active and archived Codex session JSONL files.",
                "inputSchema": emptyInputSchema(),
            ],
            [
                "name": "get_codex_account_usage",
                "description": "Read Codex account token usage summary and daily usage buckets from the local Codex app-server.",
                "inputSchema": emptyInputSchema(),
            ],
            [
                "name": "get_codex_reset_credits",
                "description": "Read available Codex rate-limit reset credits and their expiration times from the local Codex auth session.",
                "inputSchema": emptyInputSchema(),
            ],
        ]
    }

    private static func respond(id: Any, result: Any) {
        writeJSONObject(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func respondError(id: Any, code: Int, message: String) {
        writeJSONObject(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func writeJSONObject(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else {
            return
        }
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
}

enum CodexPluginInstaller {
    static func install(sourcePath: String) throws {
        let pluginName = "codex-usage-monitor"
        let marketplaceName = "personal"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let pluginSource = URL(fileURLWithPath: sourcePath)
        let installedPluginParent = home.appendingPathComponent("plugins")
        let installedPluginPath = installedPluginParent.appendingPathComponent(pluginName)
        let marketplacePath = home
            .appendingPathComponent(".agents")
            .appendingPathComponent("plugins")
            .appendingPathComponent("marketplace.json")

        guard FileManager.default.fileExists(atPath: pluginSource.appendingPathComponent(".codex-plugin/plugin.json").path) else {
            throw RuntimeError("Plugin source is missing: \(pluginSource.path)")
        }

        try FileManager.default.createDirectory(at: installedPluginParent, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: installedPluginPath)
        try FileManager.default.copyItem(at: pluginSource, to: installedPluginPath)
        try stampInstalledPluginVersion(installedPluginPath: installedPluginPath)
        try ensureMarketplace(marketplacePath: marketplacePath, pluginName: pluginName, marketplaceName: marketplaceName)
        try refreshCodexPlugin(pluginId: "\(pluginName)@\(marketplaceName)")

        print("Installed \(pluginName)@\(marketplaceName)")
        print("Marketplace: \(marketplacePath.path)")
        print("Plugin files: \(installedPluginPath.path)")
    }

    private static func stampInstalledPluginVersion(installedPluginPath: URL) throws {
        let manifestPath = installedPluginPath.appendingPathComponent(".codex-plugin/plugin.json")
        var manifest = try readJSONObject(manifestPath)
        let version = stringValue(manifest["version"]) ?? "0.1.0"
        let baseVersion = version.replacingOccurrences(of: #"\+codex\.\d+$"#, with: "", options: .regularExpression)
        let stampFormatter = DateFormatter()
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        stampFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        stampFormatter.dateFormat = "yyyyMMddHHmmss"
        manifest["version"] = "\(baseVersion)+codex.\(stampFormatter.string(from: Date()))"
        try writeJSONObject(manifest, to: manifestPath)
    }

    private static func ensureMarketplace(marketplacePath: URL, pluginName: String, marketplaceName: String) throws {
        var marketplace = (try? readJSONObject(marketplacePath)) ?? [
            "name": marketplaceName,
            "interface": ["displayName": "Personal"],
            "plugins": [],
        ]
        marketplace["name"] = stringValue(marketplace["name"]) ?? marketplaceName
        marketplace["interface"] = dictionaryValue(marketplace["interface"]) ?? ["displayName": "Personal"]
        var plugins = arrayValue(marketplace["plugins"])
        let entry: [String: Any] = [
            "name": pluginName,
            "source": ["source": "local", "path": "./plugins/\(pluginName)"],
            "policy": ["installation": "AVAILABLE", "authentication": "ON_INSTALL"],
            "category": "Productivity",
        ]
        if let index = plugins.firstIndex(where: { stringValue(dictionaryValue($0)?["name"]) == pluginName }) {
            plugins[index] = entry
        } else {
            plugins.append(entry)
        }
        marketplace["plugins"] = plugins
        try writeJSONObject(marketplace, to: marketplacePath)
    }

    private static func refreshCodexPlugin(pluginId: String) throws {
        if try isInstalled(pluginId: pluginId) {
            _ = try runCodex(args: ["plugin", "remove", pluginId, "--json"], allowFailure: true)
        }
        _ = try runCodex(args: ["plugin", "add", pluginId, "--json"], allowFailure: false)
    }

    private static func isInstalled(pluginId: String) throws -> Bool {
        let output = try runCodex(args: ["plugin", "list", "--json", "--available"], allowFailure: true)
        guard let data = output.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        return arrayValue(payload["installed"]).contains { plugin in
            stringValue(dictionaryValue(plugin)?["pluginId"]) == pluginId
        }
    }

    private static func runCodex(args: [String], allowFailure: Bool) throws -> String {
        let process = Process()
        let spec = codexCommandSpec()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments + args
        var env = [
            "PATH": "/Applications/Codex.app/Contents/Resources:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
            "NO_COLOR": "1",
        ]
        env.merge(codexManagedEnvironment(for: spec.executable)) { _, new in new }
        process.environment = env
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdoutCapture = PipeCapture()
        let stderrCapture = PipeCapture()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            stdoutCapture.append(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            stderrCapture.append(handle.availableData)
        }
        try process.run()
        process.waitUntilExit()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        stdoutCapture.append(stdout.fileHandleForReading.readDataToEndOfFile())
        stderrCapture.append(stderr.fileHandleForReading.readDataToEndOfFile())
        let stdoutText = stdoutCapture.text()
        let stderrText = stderrCapture.text()
        if process.terminationStatus != 0 && !allowFailure {
            let detail = [stdoutText, stderrText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw RuntimeError("codex \(args.joined(separator: " ")) failed\(detail.isEmpty ? "" : ":\n\(detail)")")
        }
        return stdoutText
    }

    private static func codexCommandSpec() -> (executable: String, arguments: [String]) {
        let candidates = ([ProcessInfo.processInfo.environment["CODEX_BIN"]].compactMap { $0 }
            + nativeCodexCandidates()
            + [
                "/Applications/Codex.app/Contents/Resources/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
            ]).filter { !$0.isEmpty }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return (candidate, [])
        }
        return ("/usr/bin/env", ["codex"])
    }

    private static func readJSONObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private static func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }
}

public enum CodexCommandLine {
    public static func isCLIInvocation(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        return !first.hasPrefix("-psn_")
    }

    public static func run(arguments: [String]) -> Int32 {
        guard let command = arguments.first else { return 0 }
        do {
            switch command {
            case "rate-limits", "--json":
                try writeJSON(CodexBackend.readRateLimits())
            case "usage":
                try writeJSON(CodexBackend.readTokenUsage())
            case "reset-credits":
                try writeJSON(CodexBackend.readResetCredits())
            case "combined":
                try writeJSON(CodexBackend.readCombined())
            case "local-usage":
                try writeJSON(CodexBackend.readLocalTokenUsage())
            case "status":
                try writeJSON(CodexBackend.readStatus())
            case "mcp":
                CodexMCPServer.run()
            case "install-plugin":
                let source = sourcePath(from: Array(arguments.dropFirst()))
                try CodexPluginInstaller.install(sourcePath: source)
            default:
                FileHandle.standardError.write(Data("Unknown command: \(command)\n".utf8))
                return 1
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(errorMessage(error))\n".utf8))
            return 1
        }
    }

    private static func sourcePath(from arguments: [String]) -> String {
        if let index = arguments.firstIndex(of: "--source"),
           arguments.indices.contains(index + 1)
        {
            return arguments[index + 1]
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("plugins")
            .appendingPathComponent("codex-usage-monitor")
            .path
    }
}
