import Darwin
import CryptoKit
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
        try readAccountPayload(includeUsage: false)
    }

    public static func readTokenUsage() throws -> AccountUsageSnapshot {
        let results = try callCodexAppServer(methods: ["account/usage/read"])
        return AccountUsageSnapshot(fetchedAtIso: isoNow(), usage: JSONValue.from(results["account/usage/read"]))
    }

    public static func readCombined() throws -> RateLimitPayload {
        try readAccountPayload(includeUsage: true)
    }

    static func readAccountPayload(
        includeUsage: Bool,
        sourceProvider: () -> CodexAccountSource = { CodexAccountSource() },
        call: ([String], String) throws -> [String: Any] = { try callCodexAppServer(methods: $0, codexHome: $1) },
        fetchReset: (URLRequest) throws -> Data = fetchData
    ) throws -> RateLimitPayload {
        let before = sourceProvider()
        let methods = ["account/read", "account/rateLimits/read"] + (includeUsage ? ["account/usage/read"] : [])
        let results = try call(methods, before.codexHome.path)
        let after = sourceProvider()
        guard before.matches(after) else { throw RuntimeError("Codex account changed while refreshing; retry the request.") }
        guard let response = dictionaryValue(results["account/rateLimits/read"]) else {
            throw RuntimeError("account/rateLimits/read returned invalid payload")
        }
        let account = dictionaryValue(results["account/read"]).flatMap { dictionaryValue($0["account"]) }
        let normalized = normalizeRateLimitResponse(response)
        let context = after.context(account: account, limitID: normalized.selectedRateLimit?.limitId ?? "codex")
        let resetCredits = resolveResetCredits(response: response, source: after, context: context, fetch: fetchReset)
        guard after.matches(sourceProvider()) else { throw RuntimeError("Codex account changed while refreshing; retry the request.") }
        return RateLimitPayload(
            fetchedAtIso: normalized.fetchedAtIso, rateLimits: normalized.rateLimits,
            rateLimitsByLimitId: normalized.rateLimitsByLimitId, display: normalized.display,
            resetCredits: resetCredits, localUsage: nil, rateLimitError: nil, localUsageError: nil,
            usage: includeUsage ? JSONValue.from(results["account/usage/read"]) : nil,
            accountContext: context
        )
    }

    static func resolveResetCredits(
        response: [String: Any], source: CodexAccountSource, context: CodexAccountContext,
        fetch: (URLRequest) throws -> Data
    ) -> ResetCreditsSnapshot {
        var snapshot: ResetCreditsSnapshot
        if let official = dictionaryValue(response["rateLimitResetCredits"]) {
            snapshot = normalizeResetCreditsResponse(official)
        } else {
            do {
                guard let identity = source.identityKey, identity == context.accountKey,
                      source.codexHome.path == context.codexHome, source.authFile.path == context.authenticationSource,
                      let accessToken = source.tokens["access_token"] as? String, !accessToken.isEmpty else {
                    throw RuntimeError("Reset credits unavailable: the active account's file credentials could not be verified.")
                }
                var request = URLRequest(url: resetCreditsURL)
                request.httpMethod = "GET"
                request.timeoutInterval = 12
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
                request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
                request.setValue(source.tokens["account_id"] as? String, forHTTPHeaderField: "ChatGPT-Account-ID")
                let data = try fetch(request)
                let object = try JSONSerialization.jsonObject(with: data)
                snapshot = normalizeResetCreditsResponse(dictionaryValue(object) ?? [:])
            } catch {
                snapshot = emptyResetCreditsSnapshot(error)
            }
        }
        snapshot.accountContext = context
        return snapshot
    }

    public static func readResetCredits(soft: Bool = false) throws -> ResetCreditsSnapshot {
        do {
            guard let snapshot = try readRateLimits().resetCredits else { throw RuntimeError("Reset credits unavailable") }
            if let error = snapshot.error, !soft { throw RuntimeError(error) }
            return snapshot
        } catch {
            if soft { return emptyResetCreditsSnapshot(error) }
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

        let resetCredits = ratePayload.resetCredits ?? emptyResetCreditsSnapshot(RuntimeError("reset credits unavailable"))
        let localUsage: LocalUsageSnapshot
        let localUsageError: String?
        do {
            localUsage = try readLocalTokenUsage(weeklyWindow: ratePayload.selectedRateLimit?.weeklyWindow, accountContext: ratePayload.accountContext)
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
            usage: nil,
            accountContext: ratePayload.accountContext
        )
    }

    public static func readLocalTokenUsage(weeklyWindow: RateLimitWindow? = nil,
                                           accountContext: CodexAccountContext? = nil,
                                           rebuild: Bool = false) throws -> LocalUsageSnapshot {
        let current = CodexAccountSource()
        let matches = accountContext?.accountKey != nil && accountContext?.accountKey == current.identityKey
            && accountContext?.codexHome == current.codexHome.path
        return try localUsageScanner.snapshot(weeklyWindow: matches ? weeklyWindow : nil,
                                              accountContext: accountContext,
                                              invalidateWeeklyObservation: accountContext != nil && !matches,
                                              rebuild: rebuild)
    }

    static func localUsageRootURLs(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        if let override = environment["CODEX_SESSIONS_DIR"], !override.isEmpty {
            return [URL(fileURLWithPath: override).standardizedFileURL.resolvingSymlinksInPath()]
        }
        var homes = [home.appendingPathComponent(".codex"), home.appendingPathComponent(".codex-cli")]
        if let configured = environment["CODEX_HOME"], !configured.isEmpty {
            homes.append(URL(fileURLWithPath: configured))
        }
        var seen = Set<String>()
        return homes.flatMap { root in
            [root.appendingPathComponent("sessions"), root.appendingPathComponent("archived_sessions")]
        }.map { $0.standardizedFileURL.resolvingSymlinksInPath() }.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue && seen.insert(url.path).inserted
        }
    }

    static func weeklyUsageRootURLs(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        if environment["CODEX_SESSIONS_DIR"] != nil {
            return localUsageRootURLs(environment: environment, home: home)
        }
        let activeHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        return ["sessions", "archived_sessions"].map {
            activeHome.appendingPathComponent($0).standardizedFileURL.resolvingSymlinksInPath()
        }
    }

    static func localUsageCacheURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        guard environment["CODEX_SESSIONS_DIR"] == nil else { return nil }
        let defaultHome = home.appendingPathComponent(".codex").standardizedFileURL.resolvingSymlinksInPath()
        let activeHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }?
            .standardizedFileURL.resolvingSymlinksInPath() ?? defaultHome
        var filename = "local-usage-cache.json"
        if activeHome != defaultHome {
            // Stable, non-security identifier. Swift Hasher changes across runs.
            let identifier = activeHome.path.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
                ($0 ^ UInt64($1)) &* 1_099_511_628_211
            }
            filename = "local-usage-cache-\(String(identifier, radix: 16)).json"
        }
        return home.appendingPathComponent("Library/Application Support/Codex Rate Limits Bar")
            .appendingPathComponent(filename)
    }

    private static func localUsageSourceDescription(rootURLs: [URL]) -> String {
        rootURLs.map(\.path).joined(separator: ",")
    }

    final class LocalUsageScanner: @unchecked Sendable {
        private static let readChunkSize = 1 * 1_024 * 1_024
        private static let maxBufferedLineSize = 1 * 1_024 * 1_024
        private static let retainedHistoryDays = 8
        private static let sessionMetaMarker = Data("\"type\":\"session_meta\"".utf8)
        private static let turnContextMarker = Data("\"type\":\"turn_context\"".utf8)
        private static let threadSettingsMarker = Data("\"type\":\"thread_settings_applied\"".utf8)
        private static let tokenCountMarker = Data("\"type\":\"token_count\"".utf8)

        private let lock = NSLock()
        private let rootURLsProvider: () -> [URL]
        private let weeklyRootURLsProvider: () -> [URL]
        private let nowProvider: () -> Date
        private let calendarProvider: () -> Calendar
        private let cacheFileURL: URL?
        private var cache: LocalUsageScanCache?
        private var persistentCacheSignature: LocalUsageCacheFileSignature?
        private var readBuffer = Data()
        private var copyLedger: UsageCopyLedger?
        private var copyReplayErrors: [String] = []

        init() {
            rootURLsProvider = { CodexBackend.localUsageRootURLs() }
            weeklyRootURLsProvider = { CodexBackend.weeklyUsageRootURLs() }
            nowProvider = Date.init
            calendarProvider = { .current }
            cacheFileURL = CodexBackend.localUsageCacheURL()
        }

        init(rootURLs: [URL], calendar: Calendar, now: @escaping () -> Date, cacheFileURL: URL? = nil,
             weeklyRootURLs: [URL]? = nil) {
            rootURLsProvider = { rootURLs }
            weeklyRootURLsProvider = { weeklyRootURLs ?? rootURLs }
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
            weeklyRootURLsProvider = { rootURLs }
            nowProvider = now
            self.calendarProvider = calendarProvider
            self.cacheFileURL = cacheFileURL
        }

        func snapshot(weeklyWindow: RateLimitWindow? = nil, accountContext: CodexAccountContext? = nil,
                      invalidateWeeklyObservation: Bool = false, rebuild: Bool = false) throws -> LocalUsageSnapshot {
            lock.lock()
            defer { lock.unlock() }
            defer { _ = malloc_zone_pressure_relief(nil, 0) }
            return try autoreleasepool {
                try scanLocked(weeklyWindow: weeklyWindow, accountContext: accountContext, invalidateWeeklyObservation: invalidateWeeklyObservation, rebuild: rebuild)
            }
        }

        private func scanLocked(weeklyWindow: RateLimitWindow?, accountContext: CodexAccountContext?,
                                invalidateWeeklyObservation: Bool, rebuild: Bool) throws -> LocalUsageSnapshot {
            let persistentLockFD = acquirePersistentCacheLock()
            defer { releasePersistentCacheLock(persistentLockFD) }

            let startedAt = Date()
            let now = nowProvider()
            let calendar = calendarProvider()
            let dayStart = calendar.startOfDay(for: now)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now
            let historyStart = calendar.date(
                byAdding: .day,
                value: -Self.retainedHistoryDays,
                to: dayStart
            ) ?? dayStart.addingTimeInterval(-TimeInterval(Self.retainedHistoryDays * 24 * 60 * 60))
            let localDate = CodexBackend.localDateString(now, timeZone: calendar.timeZone)
            let timeZone = calendar.timeZone.identifier
            let rootURLs = rootURLsProvider()
            let weeklyRoots = weeklyRootURLsProvider().map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
            let source = CodexBackend.localUsageSourceDescription(rootURLs: rootURLs)
            loadPersistentCache()

            let previousRoots = cache.map { Set($0.rootPaths ?? $0.source.split(separator: ",").map(String.init)) } ?? []
            let currentRoots = Set(rootURLs.map(\.path))
            // Adding a Codex home must not erase an established observation.
            let canReuseBaseline = cache?.timeZone == timeZone
                && (cache?.source == source || (!previousRoots.isEmpty && previousRoots.isSubset(of: currentRoots)))
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
                    files: previous.files.mapValues { $0.resetForNewDay() },
                    weeklyCostObservation: previous.weeklyCostObservation
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
            if cache.source != source {
                cache.source = source
                cacheChanged = true
            }

            if cache.rootPaths != rootURLs.map(\.path) {
                cache.rootPaths = rootURLs.map(\.path)
                cacheChanged = true
            }
            copyReplayErrors = []
            let discoveryStart = max(historyStart, min(dayStart, cache.weeklyCostObservation?.startedAt ?? dayStart))
            var byPath: [String: JsonlFileInfo] = [:]
            for root in rootURLs {
                for var file in CodexBackend.walkJsonlFileInfos(root: root, dayStart: historyStart) {
                    guard rebuild || file.modifiedAt >= discoveryStart || cache.files[file.url.path] != nil else { continue }
                    let state = cache.files[file.url.path]
                    file.sessionID = state?.fileStamp == file.stamp ? state?.primarySessionId : UsageFileIdentity.sessionID(at: file.url)
                    // An unreadable replacement must remain in its old copy
                    // transaction until its new session identity is available.
                    if file.sessionID == nil {
                        file.sessionID = state?.primarySessionId
                    }
                    byPath[file.url.path] = file
                }
            }
            let files = byPath.values.sorted { $0.url.path < $1.url.path }
            var stats = LocalUsageScanStats()
            stats.filesScanned = files.count

            if invalidateWeeklyObservation, cache.weeklyCostObservation != nil {
                cache.weeklyCostObservation = nil
                for path in Array(cache.files.keys) { cache.files[path]?.weeklyCost = nil }
                cacheChanged = true
            }
            cacheChanged = updateWeeklyCostObservation(
                cache: &cache, window: weeklyWindow, now: now, rootPaths: weeklyRoots, accountContext: accountContext
            ) || cacheChanged
            cacheChanged = reconcileCachedFiles(files, cache: &cache, historyStart: historyStart) || cacheChanged

            let groups = Dictionary(grouping: files) { file in
                file.sessionID.map { "session:" + $0 } ?? "file:" + file.url.path
            }
            let missingSessions = Set(cache.files.compactMap { path, state in byPath[path] == nil ? state.primarySessionId : nil })
            for key in groups.keys.sorted() {
                let members = groups[key]!.sorted { $0.url.path < $1.url.path }
                let paths = members.map(\.url.path)
                let hasCopies = members.count > 1
                let replayCopies = hasCopies && (rebuild || members.contains { file in
                    guard let state = cache.files[file.url.path] else { return true }
                    return state.fileStamp != file.stamp || state.requiresCostRebuild || state.prefixDigest == nil || state.hasUsageBounds != true
                        || state.copyMembers != paths || state.copyDay != localDate
                })
                let lostCopy = members.first?.sessionID.map { missingSessions.contains($0) } ?? false
                if lostCopy {
                    copyReplayErrors.append("A session copy is missing; retained its last verified totals: " + (members.first?.sessionID ?? key))
                    continue
                }
                if hasCopies && !replayCopies { continue }
                // Unchanged copies entirely before the active day/observation
                // cannot overlap any newly counted event. Keep this common case
                // incremental even when their old histories diverge.
                let activityStart = min(dayStart, cache.weeklyCostObservation?.startedAt ?? dayStart)
                let changedMembers = members.filter { cache.files[$0.url.path]?.fileStamp != $0.stamp }
                if hasCopies, !rebuild, changedMembers.count == 1,
                   members.allSatisfy({ file in
                       guard let state = cache.files[file.url.path] else { return false }
                       return state.copyMembers == paths && state.copyDay == localDate && state.hasUsageBounds == true
                           && state.prefixDigest != nil && !state.requiresCostRebuild
                   }),
                   members.filter({ $0.url.path != changedMembers[0].url.path }).allSatisfy({ file in
                       (cache.files[file.url.path]?.latestUsageAt ?? .distantPast) < activityStart
                   }) {
                    let file = changedMembers[0]
                    let previousFailures = stats.readFailureCount
                    cacheChanged = scan(file, cache: &cache, historyStart: historyStart, now: now, stats: &stats) || cacheChanged
                    cache.files[file.url.path]?.copyMembers = paths
                    cache.files[file.url.path]?.copyDay = localDate
                    if stats.readFailureCount > previousFailures {
                        copyReplayErrors.append("Could not refresh session copies; retained their previous totals: " + key)
                    }
                    continue
                }
                let previousStates = Dictionary(uniqueKeysWithValues: paths.compactMap { path in cache.files[path].map { (path, $0) } })
                let previousFailures = stats.readFailureCount
                if replayCopies { copyLedger = UsageCopyLedger() }
                for file in members {
                    copyLedger?.path = file.url.path
                    copyLedger?.isWeeklySource = weeklyRoots.contains { file.url.path.hasPrefix($0 + "/") }
                    let wasCopy = (cache.files[file.url.path]?.copyMembers?.count ?? 0) > 1
                    cacheChanged = scan(file, cache: &cache, historyStart: historyStart, now: now, stats: &stats,
                                        force: rebuild || replayCopies || (wasCopy && !hasCopies)) || cacheChanged
                    if hasCopies {
                        cache.files[file.url.path]?.copyMembers = paths
                        cache.files[file.url.path]?.copyDay = localDate
                    }
                }
                let completedLedger = copyLedger
                copyLedger = nil
                if replayCopies && stats.readFailureCount > previousFailures {
                    for path in paths { cache.files[path] = previousStates[path] }
                    copyReplayErrors.append("Could not rebuild session copies; retained their previous totals: " + key)
                } else if let completedLedger {
                    applyCopyContributions(completedLedger, cache: &cache)
                }
            }

            self.cache = cache
            if cacheChanged {
                persist(cache)
            }
            let snapshot = makeSnapshot(
                cache: cache,
                filesScanned: files.count,
                now: now,
                weeklyWindow: weeklyWindow,
                accountContext: accountContext
            )
            stats.durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            log(stats: stats, coldScan: isColdScan)
            return snapshot
        }

        private func applyCopyContributions(_ ledger: UsageCopyLedger, cache: inout LocalUsageScanCache) {
            for key in ledger.contributions.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                let event = ledger.contributions[key]!
                if let path = event.dailyOwner, var state = cache.files[path] {
                    state.totals.add(event.usage)
                    var cost = state.dailyCost ?? TokenCostAccumulator()
                    cost.add(usage: event.usage, model: event.model, requestInputTokens: event.requestInput, serviceTier: event.tier)
                    state.dailyCost = cost
                    state.eventCount += 1
                    if (parseIsoDate(state.lastEventAtIso) ?? .distantPast) < (parseIsoDate(event.timestamp) ?? .distantPast) {
                        state.lastEventAtIso = event.timestamp
                    }
                    cache.files[path] = state
                }
                if let path = event.weeklyOwner {
                    var cost = cache.files[path]?.weeklyCost ?? TokenCostAccumulator()
                    cost.add(usage: event.usage, model: event.model, requestInputTokens: event.requestInput, serviceTier: event.tier)
                    cache.files[path]?.weeklyCost = cost
                }
            }
        }

        private func loadPersistentCache() {
            guard let cacheFileURL,
                  let signature = cacheFileSignature(for: cacheFileURL),
                  signature != persistentCacheSignature
            else { return }

            guard let data = try? Data(contentsOf: cacheFileURL) else { return }

            do {
                let document = try JSONDecoder().decode(LocalUsageCacheDocument.self, from: data)
                if document.version == LocalUsageCacheDocument.currentVersion {
                    cache = document.cache
                } else {
                    cache = nil
                }
            } catch {
                cache = nil
                appendSharedLog("local usage cache ignored: \(errorMessage(error))")
            }
            persistentCacheSignature = signature
        }

        private func cacheFileSignature(for url: URL) -> LocalUsageCacheFileSignature? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber,
                  let modifiedAt = attributes[.modificationDate] as? Date
            else { return nil }
            return LocalUsageCacheFileSignature(
                fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                size: size.uint64Value,
                modifiedAt: modifiedAt
            )
        }

        private func acquirePersistentCacheLock() -> Int32? {
            guard let cacheFileURL else { return nil }
            do {
                try FileManager.default.createDirectory(
                    at: cacheFileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                appendSharedLog("local usage lock directory failed: \(errorMessage(error))")
                return nil
            }

            let lockURL = cacheFileURL.appendingPathExtension("lock")
            let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                appendSharedLog("local usage lock open failed: errno=\(errno)")
                return nil
            }
            guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
                appendSharedLog("local usage lock acquire failed: errno=\(errno)")
                Darwin.close(descriptor)
                return nil
            }
            return descriptor
        }

        private func releasePersistentCacheLock(_ descriptor: Int32?) {
            guard let descriptor else { return }
            _ = Darwin.lockf(descriptor, F_ULOCK, 0)
            Darwin.close(descriptor)
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
                persistentCacheSignature = cacheFileSignature(for: cacheFileURL)
            } catch {
                appendSharedLog("local usage cache write failed: \(errorMessage(error))")
            }
        }

        private func reconcileCachedFiles(
            _ files: [JsonlFileInfo],
            cache: inout LocalUsageScanCache,
            historyStart: Date
        ) -> Bool {
            var changed = false
            let currentPaths = Set(files.map(\.url.path))
            let filesBySession = Dictionary(grouping: files.filter { $0.sessionID != nil }) { $0.sessionID! }
            for path in Array(cache.files.keys).sorted() where !currentPaths.contains(path) {
                guard let old = cache.files[path] else { continue }
                // Legacy caches may retain a moved path without a fingerprint.
                // An entry with no current contribution cannot cause overlap;
                // retire it so it cannot block replay of the archived history.
                if old.totals.totalTokens == 0, old.eventCount == 0, old.importedEventCount == 0,
                   old.parseErrorCount == 0, old.weeklyCost == nil {
                    cache.files.removeValue(forKey: path)
                    changed = true
                    continue
                }
                for file in old.primarySessionId.flatMap({ filesBySession[$0] }) ?? [] {
                    var sameContent = old.fileStamp?.identity == file.stamp.identity
                    if !sameContent, file.size >= old.offset, let expected = old.prefixDigest,
                       let handle = try? FileHandle(forReadingFrom: file.url) {
                        defer { try? handle.close() }
                        sameContent = (try? UsageFileIdentity.digest(UsageFileIdentity.prefixHasher(handle, count: old.offset))) == expected
                    }
                    guard sameContent else { continue }
                    if cache.files[file.url.path] == nil {
                        cache.files[file.url.path] = old
                    } else {
                        // A copy can own zero daily contributions while another
                        // copy owns the shared prefix. Replay before retiring it.
                        cache.files[file.url.path]?.prefixDigest = nil
                    }
                    cache.files.removeValue(forKey: path)
                    changed = true
                    break
                }
            }

            let livePaths = Set(files.map(\.url.path))
            for path in Array(cache.files.keys) {
                guard let state = cache.files[path] else { continue }
                let shouldKeep = livePaths.contains(path)
                    || state.modifiedAt.map { $0 >= historyStart } == true
                if shouldKeep {
                    continue
                } else {
                    cache.files.removeValue(forKey: path)
                    changed = true
                }
            }
            return changed
        }

        private func updateWeeklyCostObservation(
            cache: inout LocalUsageScanCache,
            window: RateLimitWindow?,
            now: Date,
            rootPaths: [String],
            accountContext: CodexAccountContext?
        ) -> Bool {
            guard accountContext == nil || accountContext?.scopeKey != nil else { return false }
            guard let window,
                  let windowID = QuotaWindowID(window: window),
                  let durationMinutes = window.windowDurationMins,
                  let windowEnd = window.resetDate
            else {
                return false
            }
            let windowStart = windowEnd.addingTimeInterval(-TimeInterval(durationMinutes * 60))
            guard windowStart <= now, now <= windowEnd else { return false }

            let usedPercent = max(0, min(100, max(window.usedPercent, 100 - window.remainingPercent)))
            if let observation = cache.weeklyCostObservation,
               observation.accountScopeKey == accountContext?.scopeKey,
               observation.windowID == windowID,
               observation.startedAt >= windowStart,
               observation.startedAt <= now,
               observation.baselineUsedPercent <= usedPercent,
               observation.rootPaths.map({ Set($0).isSubset(of: Set(rootPaths)) }) ?? true {
                if observation.rootPaths != rootPaths {
                    cache.weeklyCostObservation?.rootPaths = rootPaths
                    return true
                }
                return false
            }

            cache.weeklyCostObservation = LocalUsageWeeklyCostObservation(
                windowID: windowID,
                startedAt: now,
                baselineUsedPercent: usedPercent,
                rootPaths: rootPaths,
                accountScopeKey: accountContext?.scopeKey
            )
            for path in Array(cache.files.keys) {
                cache.files[path]?.weeklyCost = nil
            }
            return true
        }

        private func scan(
            _ file: JsonlFileInfo, cache: inout LocalUsageScanCache, historyStart: Date,
            now: Date, stats: inout LocalUsageScanStats, force: Bool = false
        ) -> Bool {
            let path = file.url.path
            let previousState = cache.files[path]
            var state = previousState ?? LocalUsageFileState()
            var replay = force || state.requiresCostRebuild || state.prefixDigest == nil || state.hasUsageBounds != true
                || file.size < state.offset || state.fileStamp?.identity != file.stamp.identity
            if !replay, state.fileStamp == file.stamp, file.size == state.offset { return false }
            do {
                let handle = try FileHandle(forReadingFrom: file.url)
                defer { try? handle.close() }
                var hasher = SHA256()
                if !replay {
                    hasher = try UsageFileIdentity.prefixHasher(handle, count: state.offset)
                    stats.verificationBytes += state.offset
                    if UsageFileIdentity.digest(hasher) != state.prefixDigest { replay = true }
                }
                if replay {
                    state = LocalUsageFileState()
                    hasher = SHA256()
                    stats.fullRescanFiles += 1
                }
                try handle.seek(toOffset: state.offset)
                var remaining = file.size - state.offset
                while remaining > 0 {
                    let count = min(Self.readChunkSize, Int(remaining))
                    if readBuffer.count != Self.readChunkSize { readBuffer = Data(count: Self.readChunkSize) }
                    let bytesRead = readBuffer.withUnsafeMutableBytes { buffer -> Int in
                        guard let baseAddress = buffer.baseAddress else { return 0 }
                        var result: Int
                        repeat { result = Darwin.read(handle.fileDescriptor, baseAddress, count) } while result < 0 && errno == EINTR
                        return result
                    }
                    guard bytesRead > 0 else { throw RuntimeError("Session file changed or could not be read") }
                    let chunk = readBuffer.prefix(bytesRead)
                    hasher.update(data: chunk)
                    state.offset += UInt64(bytesRead)
                    remaining -= UInt64(bytesRead)
                    stats.bytesRead += UInt64(bytesRead)
                    process(data: chunk, state: &state, dayStart: cache.dayStart, dayEnd: cache.dayEnd,
                            historyStart: historyStart, weeklyObservationStart: cache.weeklyCostObservation?.startedAt, now: now)
                }
                if UsageFileStamp.read(file.url) != file.stamp {
                    guard let current = UsageFileStamp.read(file.url), current.identity == file.stamp.identity,
                          current.size >= file.size,
                          UsageFileIdentity.digest(try UsageFileIdentity.prefixHasher(handle, count: file.size)) == UsageFileIdentity.digest(hasher)
                    else { throw RuntimeError("Session file changed during scanning; retrying on the next refresh") }
                    stats.verificationBytes += file.size
                }
                state.size = file.size
                state.modifiedAt = file.modifiedAt
                state.fileStamp = file.stamp
                state.hasUsageBounds = true
                state.prefixDigest = UsageFileIdentity.digest(hasher)
                cache.files[path] = state
                stats.filesRead += 1
                return true
            } catch {
                stats.readFailureCount += 1
                appendSharedLog("local usage scan read failure: \(path): \(errorMessage(error))")
                // Commit the cursor and totals together only after a verified read.
                return false
            }
        }

        private func process(
            data: Data,
            state: inout LocalUsageFileState,
            dayStart: Date,
            dayEnd: Date,
            historyStart: Date,
            weeklyObservationStart: Date?,
            now: Date
        ) {
            guard !data.isEmpty else { return }
            if state.pendingData.count > Self.maxBufferedLineSize {
                state.pendingData.removeAll(keepingCapacity: false)
                state.isSkippingOversizedLine = true
            }

            var cursor = data.startIndex
            while cursor < data.endIndex {
                if state.isSkippingOversizedLine == true {
                    guard let newlineIndex = data[cursor...].firstIndex(of: 0x0A) else { return }
                    state.isSkippingOversizedLine = false
                    cursor = data.index(after: newlineIndex)
                    continue
                }

                guard let newlineIndex = data[cursor...].firstIndex(of: 0x0A) else {
                    let fragment = data[cursor...]
                    if state.pendingData.count + fragment.count > Self.maxBufferedLineSize {
                        state.pendingData.removeAll(keepingCapacity: false)
                        state.isSkippingOversizedLine = true
                    } else {
                        state.pendingData.append(contentsOf: fragment)
                    }
                    return
                }

                let fragment = data[cursor..<newlineIndex]
                if state.pendingData.isEmpty {
                    if fragment.count <= Self.maxBufferedLineSize {
                        processCompleteLine(
                            fragment,
                            state: &state,
                            dayStart: dayStart,
                            dayEnd: dayEnd,
                            historyStart: historyStart,
                            weeklyObservationStart: weeklyObservationStart,
                            now: now
                        )
                    }
                } else if state.pendingData.count + fragment.count <= Self.maxBufferedLineSize {
                    state.pendingData.append(contentsOf: fragment)
                    let completedLine = state.pendingData
                    state.pendingData.removeAll(keepingCapacity: false)
                    processCompleteLine(
                        completedLine,
                        state: &state,
                        dayStart: dayStart,
                        dayEnd: dayEnd,
                        historyStart: historyStart,
                        weeklyObservationStart: weeklyObservationStart,
                        now: now
                    )
                } else {
                    state.pendingData.removeAll(keepingCapacity: false)
                }
                cursor = data.index(after: newlineIndex)
            }
        }

        private func processCompleteLine(
            _ data: Data,
            state: inout LocalUsageFileState,
            dayStart: Date,
            dayEnd: Date,
            historyStart: Date,
            weeklyObservationStart: Date?,
            now: Date
        ) {
            let lineData = trimmedLineData(data)
            guard isPotentialUsageLine(lineData) else { return }
            autoreleasepool {
                processLine(
                    lineData,
                    state: &state,
                    dayStart: dayStart,
                    dayEnd: dayEnd,
                    historyStart: historyStart,
                    weeklyObservationStart: weeklyObservationStart,
                    now: now
                )
            }
        }

        private func isPotentialUsageLine(_ data: Data) -> Bool {
            let prefix = data.prefix(1_024)
            if prefix.range(of: Self.sessionMetaMarker) != nil
                || prefix.range(of: Self.turnContextMarker) != nil
                || prefix.range(of: Self.threadSettingsMarker) != nil
                || prefix.range(of: Self.tokenCountMarker) != nil
            {
                return true
            }
            let suffix = data.suffix(256)
            return suffix.range(of: Self.sessionMetaMarker) != nil
                || suffix.range(of: Self.turnContextMarker) != nil
                || suffix.range(of: Self.threadSettingsMarker) != nil
                || suffix.range(of: Self.tokenCountMarker) != nil
        }

        private func trimmedLineData(_ data: Data) -> Data {
            guard data.last == 0x0D else { return data }
            return data.dropLast()
        }

        private func processLine(
            _ lineData: Data,
            state: inout LocalUsageFileState,
            dayStart: Date,
            dayEnd: Date,
            historyStart: Date,
            weeklyObservationStart: Date?,
            now: Date
        ) {
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
                state.currentServiceTier = dictionaryValue(object["payload"]).flatMap(CodexBackend.serviceTierFromPayload)
                if let payload = dictionaryValue(object["payload"]),
                   let model = CodexBackend.modelFromPayload(payload) {
                    state.currentModel = model
                }
                return
            }

            if stringValue(object["type"]) == "turn_context",
               let payload = dictionaryValue(object["payload"]) {
                // A full turn context replaces the tier, including an absent tier.
                state.currentServiceTier = CodexBackend.serviceTierFromPayload(payload)
                if let model = CodexBackend.modelFromPayload(payload) {
                    state.currentModel = model
                }
                return
            }

            guard stringValue(object["type"]) == "event_msg",
                  let payload = dictionaryValue(object["payload"]),
                  let eventType = stringValue(payload["type"])
            else {
                return
            }
            if eventType == "thread_settings_applied" {
                if CodexBackend.hasServiceTierSetting(payload) {
                    state.currentServiceTier = CodexBackend.serviceTierFromPayload(payload)
                }
                if let model = CodexBackend.modelFromPayload(payload) {
                    state.currentModel = model
                }
                return
            }

            guard eventType == "token_count",
                  let info = dictionaryValue(payload["info"]),
                  let currentTotalUsage = TokenUsage.from(info["total_token_usage"])
            else {
                return
            }

            let timestamp = parseIsoDate(stringValue(object["timestamp"]))
            if let timestamp, timestamp > (state.latestUsageAt ?? .distantPast) { state.latestUsageAt = timestamp }
            let isToday = timestamp.map { $0 >= dayStart && $0 < dayEnd } ?? false
            let isInHistory = timestamp.map { $0 >= historyStart && $0 < dayEnd } ?? false
            let isImportedForkEvent = state.primarySessionId != nil
                && state.activeSessionId != nil
                && state.activeSessionId != state.primarySessionId
            let sameSession = state.previousUsageSessionId == state.activeSessionId
            let baseline = sameSession ? state.previousTotalUsage : state.previousObservedTotalUsage
            let regressed = sameSession && CodexBackend.usageRegressed(baseline, currentTotalUsage)
            let delta = CodexBackend.positiveDelta(baseline, currentTotalUsage, sameSession: sameSession)

            let model = CodexBackend.modelFromPayload(info) ?? CodexBackend.modelFromPayload(payload) ?? state.currentModel
            let requestInputTokens = TokenUsage.from(info["last_token_usage"])?.inputTokens
            let serviceTier = CodexBackend.serviceTierFromPayload(info)
                ?? CodexBackend.serviceTierFromPayload(payload) ?? state.currentServiceTier
            let eventKey = (isInHistory ? copyLedger : nil).map { _ in
                UsageCopyLedger.eventKey(session: state.primarySessionId, activeSession: state.activeSessionId,
                                         timestamp: timestamp, usage: currentTotalUsage, model: model, tier: serviceTier,
                                         requestInput: requestInputTokens, imported: isImportedForkEvent)
            }
            let countToday = isToday && (eventKey.map { copyLedger!.claimDaily($0) } ?? true)
            if isInHistory {
                if isImportedForkEvent {
                    if countToday {
                        state.importedEventCount += 1
                    }
                } else if let delta {
                    let countWeekly = timestamp.map { time in
                        weeklyObservationStart.map { time > $0 && time <= now } ?? false
                    } ?? false
                    if let copyLedger, let eventKey {
                        copyLedger.record(key: eventKey, usage: delta, model: model, tier: serviceTier,
                                          requestInput: requestInputTokens, timestamp: stringValue(object["timestamp"]),
                                          today: isToday, weekly: countWeekly)
                    } else {
                        if countToday {
                            state.totals.add(delta)
                            var dailyCost = state.dailyCost ?? TokenCostAccumulator()
                            dailyCost.add(
                                usage: delta,
                                model: model,
                                requestInputTokens: requestInputTokens,
                                serviceTier: serviceTier
                            )
                            state.dailyCost = dailyCost
                            state.eventCount += 1
                            state.lastEventAtIso = stringValue(object["timestamp"])
                        }
                        if countWeekly {
                            var weeklyCost = state.weeklyCost ?? TokenCostAccumulator()
                            weeklyCost.add(
                                usage: delta,
                                model: model,
                                requestInputTokens: requestInputTokens,
                                serviceTier: serviceTier
                            )
                            state.weeklyCost = weeklyCost
                        }
                    }
                } else if countToday {
                    state.duplicateEventCount += 1
                    if regressed {
                        state.regressionEventCount += 1
                    }
                    state.eventCount += 1
                    state.lastEventAtIso = stringValue(object["timestamp"])
                }
            }

            if sameSession || !CodexBackend.usageRegressed(state.previousTotalUsage, currentTotalUsage) {
                state.previousTotalUsage = CodexBackend.maxTokenUsage(state.previousTotalUsage, currentTotalUsage)
            } else {
                state.previousTotalUsage = currentTotalUsage
            }
            state.previousUsageSessionId = state.activeSessionId
            state.previousObservedTotalUsage = currentTotalUsage
        }

        private func makeSnapshot(
            cache: LocalUsageScanCache,
            filesScanned: Int,
            now: Date,
            weeklyWindow: RateLimitWindow?,
            accountContext: CodexAccountContext?
        ) -> LocalUsageSnapshot {
            var totals = TokenUsage()
            var topFiles: [LocalUsageTopFile] = []
            var eventCount = 0
            var duplicateEventCount = 0
            var importedEventCount = 0
            var regressionEventCount = 0
            var filesWithEvents = 0
            var parseErrorCount = 0
            var todayCostAccumulator = TokenCostAccumulator()
            var weeklyCostAccumulator = TokenCostAccumulator()
            let weeklyRoots = cache.weeklyCostObservation?.rootPaths ?? weeklyRootURLsProvider().map(\.path)

            for (path, state) in cache.files {
                totals.add(state.totals)
                eventCount += state.eventCount
                duplicateEventCount += state.duplicateEventCount
                importedEventCount += state.importedEventCount
                regressionEventCount += state.regressionEventCount
                parseErrorCount += state.parseErrorCount
                if let dailyCost = state.dailyCost {
                    todayCostAccumulator.merge(dailyCost)
                }
                // Daily usage spans local homes, while quota observations must
                // match the home used by the official rate-limit request.
                if let weeklyCost = state.weeklyCost {
                    let canonicalPath = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
                    if weeklyRoots.contains(where: { canonicalPath.hasPrefix($0 + "/") }) {
                        weeklyCostAccumulator.merge(weeklyCost)
                    }
                }

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
                    lastEventAtIso: state.lastEventAtIso,
                    sourceFiles: state.copyMembers ?? [path]
                ))
            }

            let cacheHitPercent = totals.inputTokens > 0
                ? max(0, min(100, (Double(totals.cachedInputTokens) / Double(totals.inputTokens)) * 100))
                : nil
            topFiles.sort { $0.totalTokens > $1.totalTokens }
            let todayCost = todayCostAccumulator.estimate()
            let todayCredits = todayCostAccumulator.creditEstimate()
            let weeklyQuotaCost = makeWeeklyQuotaCost(
                observed: weeklyCostAccumulator.estimate(),
                window: weeklyWindow,
                observation: cache.weeklyCostObservation,
                now: now
            )

            return LocalUsageSnapshot(
                fetchedAtIso: ISO8601DateFormatter().string(from: now),
                source: cache.source,
                timezone: cache.timeZone,
                localDate: cache.localDate,
                inputTokens: totals.inputTokens,
                cachedInputTokens: totals.cachedInputTokens,
                cacheWriteInputTokens: totals.cacheWriteInputTokens,
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
                error: copyReplayErrors.isEmpty ? nil : copyReplayErrors.joined(separator: "\n"),
                topFiles: Array(topFiles.prefix(8)),
                todayCost: todayCost,
                weeklyQuotaCost: weeklyQuotaCost,
                display: LocalUsageDisplay(
                    consumptionLabel: AppText.consumption(TokenAmountFormatter.compact(totals.totalTokens)),
                    cacheHitLabel: AppText.cacheHit(CodexBackend.formatCacheHitPercent(cacheHitPercent)),
                    estimatedCostLabel: AppText.todayEstimatedCost(todayCost),
                    weeklyQuotaCostLabel: weeklyWindow == nil
                        ? nil
                        : AppText.weeklyQuotaEstimatedCost(weeklyQuotaCost),
                    estimatedCreditsLabel: AppText.todayEstimatedCredits(todayCredits),
                    pricingCoverageLabel: AppText.pricingCoverage(cost: todayCost, credits: todayCredits)
                ),
                todayCredits: todayCredits,
                accountContext: accountContext
            )
        }

        private func makeWeeklyQuotaCost(
            observed: UsageCostEstimate,
            window: RateLimitWindow?,
            observation: LocalUsageWeeklyCostObservation?,
            now: Date
        ) -> WeeklyQuotaCostEstimate? {
            guard let window,
                  let windowID = QuotaWindowID(window: window),
                  let observation,
                  observation.windowID == windowID,
                  let durationMinutes = window.windowDurationMins,
                  durationMinutes > 0,
                  let windowEnd = window.resetDate
            else {
                return nil
            }
            let windowStart = windowEnd.addingTimeInterval(-TimeInterval(durationMinutes * 60))
            guard windowStart <= now, now <= windowEnd else { return nil }

            let usedPercent = max(0, min(100, max(window.usedPercent, 100 - window.remainingPercent)))
            let usedDeltaPercent = max(0, usedPercent - observation.baselineUsedPercent)
            let estimatedQuotaUSD: Double?
            if usedDeltaPercent >= 2,
               observed.coveragePercent >= 95,
               observed.pricedTokens > 0,
               let observedCostUSD = observed.estimatedCostUSD {
                estimatedQuotaUSD = observedCostUSD * 100 / Double(usedDeltaPercent)
            } else {
                estimatedQuotaUSD = nil
            }
            let formatter = ISO8601DateFormatter()
            return WeeklyQuotaCostEstimate(
                windowStartIso: formatter.string(from: windowStart),
                windowEndIso: formatter.string(from: windowEnd),
                observationStartIso: formatter.string(from: observation.startedAt),
                baselineUsedPercent: observation.baselineUsedPercent,
                usedPercent: usedPercent,
                usedDeltaPercent: usedDeltaPercent,
                observedCostUSD: observed.estimatedCostUSD,
                estimatedQuotaUSD: estimatedQuotaUSD,
                coveragePercent: observed.coveragePercent,
                pricedTokens: observed.pricedTokens,
                unpricedTokens: observed.unpricedTokens,
                unpricedModels: observed.unpricedModels,
                source: observation.rootPaths?.joined(separator: ","),
                accountScopeKey: observation.accountScopeKey
            )
        }

        private func log(stats: LocalUsageScanStats, coldScan: Bool) {
            guard stats.bytesRead > 0 || stats.fullRescanFiles > 0 || stats.readFailureCount > 0 || stats.durationMs > 1000 else {
                return
            }
            appendSharedLog("local usage scan files=\(stats.filesScanned) readFiles=\(stats.filesRead) bytes=\(stats.bytesRead) verificationBytes=\(stats.verificationBytes) durationMs=\(stats.durationMs) fullRescanFiles=\(stats.fullRescanFiles) cold=\(coldScan) readFailures=\(stats.readFailureCount)")
        }
    }

    private struct LocalUsageCacheDocument: Codable {
        static let currentVersion = 4

        var version = currentVersion
        let cache: LocalUsageScanCache
    }

    private struct LocalUsageScanCache: Codable {
        var source: String
        var rootPaths: [String]?
        let localDate: String
        let timeZone: String
        var dayStart: Date
        var dayEnd: Date
        var files: [String: LocalUsageFileState] = [:]
        var weeklyCostObservation: LocalUsageWeeklyCostObservation?
    }

    private struct LocalUsageWeeklyCostObservation: Codable {
        let windowID: QuotaWindowID
        let startedAt: Date
        let baselineUsedPercent: Int
        var rootPaths: [String]?
        var accountScopeKey: String?
    }

    private struct LocalUsageFileState: Codable {
        var offset: UInt64 = 0
        var size: UInt64 = 0
        var modifiedAt: Date?
        var fileStamp: UsageFileStamp?
        var prefixDigest: String?
        var copyMembers: [String]?
        var copyDay: String?
        var latestUsageAt: Date?
        var hasUsageBounds: Bool?
        var pendingData = Data()
        var isSkippingOversizedLine: Bool?
        var previousTotalUsage: TokenUsage?
        var previousObservedTotalUsage: TokenUsage?
        var previousUsageSessionId: String?
        var primarySessionId: String?
        var activeSessionId: String?
        var currentModel: String?
        var currentServiceTier: String?
        var totals = TokenUsage()
        var dailyCost: TokenCostAccumulator?
        var weeklyCost: TokenCostAccumulator?
        var eventCount = 0
        var duplicateEventCount = 0
        var importedEventCount = 0
        var regressionEventCount = 0
        var parseErrorCount = 0
        var lastEventAtIso: String?

        var requiresCostRebuild: Bool {
            dailyCost?.requiresRepricing == true || weeklyCost?.requiresRepricing == true
        }

        func resetForNewDay() -> LocalUsageFileState {
            var state = self
            state.totals = TokenUsage()
            state.eventCount = 0
            state.duplicateEventCount = 0
            state.importedEventCount = 0
            state.regressionEventCount = 0
            state.parseErrorCount = 0
            state.lastEventAtIso = nil
            state.dailyCost = nil
            return state
        }
    }

    private struct LocalUsageCacheFileSignature: Equatable {
        let fileNumber: UInt64
        let size: UInt64
        let modifiedAt: Date
    }

    private struct LocalUsageScanStats {
        var filesScanned = 0
        var filesRead = 0
        var bytesRead: UInt64 = 0
        var verificationBytes: UInt64 = 0
        var fullRescanFiles = 0
        var readFailureCount = 0
        var durationMs = 0
    }

    static func normalizeRateLimitResponse(_ response: [String: Any]) -> RateLimitPayload {
        let rateLimits = normalizeSnapshot(dictionaryValue(response["rateLimits"]))
        var byLimitId: [String: RateLimitSnapshot] = [:]
        for (limitId, value) in dictionaryValue(response["rateLimitsByLimitId"]) ?? [:] {
            byLimitId[limitId] = normalizeSnapshot(dictionaryValue(value))
        }
        let weekly = (byLimitId["codex"] ?? rateLimits)?.weeklyWindow
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

    static func normalizeResetCreditsResponse(_ response: [String: Any]) -> ResetCreditsSnapshot {
        var credits = arrayValue(response["credits"])
            .compactMap { normalizeResetCredit(dictionaryValue($0)) }
        credits.sort { resetCreditSortKey($0) < resetCreditSortKey($1) }

        let fallbackAvailableCount = credits.filter { $0.status == "available" }.count
        let availableCount = intValue(response["availableCount"] ?? response["available_count"])
            ?? (response["credits"] is [Any] ? fallbackAvailableCount : nil)
        let firstTypeLabel = credits.first?.typeLabel ?? AppText.resetCreditsCategory
        let visibleSource = credits.contains { $0.status == "available" }
            ? credits.filter { $0.status == "available" }
            : credits
        var detailLabels = Array(visibleSource.prefix(4)).enumerated().map { index, credit in
            AppText.resetCreditDetail(
                index: index + 1,
                status: credit.statusLabel,
                expiresAt: credit.expiresAtShortLabel
            )
        }
        if detailLabels.isEmpty, (availableCount ?? 0) > 0 {
            detailLabels = [AppText.resetCreditDetailsUnavailable]
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
            ),
            detailsAvailable: response["credits"] is [Any]
        )
    }

    private static func normalizeResetCredit(_ credit: [String: Any]?) -> ResetCreditItem? {
        guard let credit else { return nil }
        let resetType = stringValue(credit["resetType"] ?? credit["reset_type"]) ?? stringValue(credit["type"]) ?? "unknown"
        let status = stringValue(credit["status"])
        let createdAtIso = isoString(credit["grantedAt"] ?? credit["created_at"] ?? credit["granted_at"])
        let expiresAtIso = isoString(credit["expiresAt"] ?? credit["expires_at"])
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
            cacheWriteInputTokens: 0,
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
            todayCost: nil,
            weeklyQuotaCost: nil,
            display: LocalUsageDisplay(
                consumptionLabel: AppText.consumption(nil),
                cacheHitLabel: AppText.cacheHit(nil),
                estimatedCostLabel: nil,
                weeklyQuotaCostLabel: nil
            )
        )
    }

    private static func callCodexAppServer(methods: [String], codexHome: String? = nil, timeout: TimeInterval = 12) throws -> [String: Any] {
        let spec = codexCommandSpec()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments + ["app-server", "--stdio"]
        process.environment = processEnvironment(codexExecutable: spec.executable)
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
        let stamp: UsageFileStamp
        var sessionID: String?
        var modifiedAt: Date { stamp.modifiedAt }
        var size: UInt64 { stamp.size }
    }

    private static func walkJsonlFileInfos(root: URL, dayStart: Date) -> [JsonlFileInfo] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var files: [JsonlFileInfo] = []
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            let canonical = file.standardizedFileURL.resolvingSymlinksInPath()
            guard let stamp = UsageFileStamp.read(canonical), stamp.modifiedAt >= dayStart else { continue }
            files.append(JsonlFileInfo(url: canonical, stamp: stamp))
        }
        return files
    }

    private static func sessionIdFromMeta(_ event: [String: Any]) -> String? {
        guard stringValue(event["type"]) == "session_meta",
              let payload = dictionaryValue(event["payload"])
        else {
            return nil
        }
        return stringValue(payload["id"]) ?? stringValue(payload["session_id"])
    }

    private static func modelFromPayload(_ payload: [String: Any]) -> String? {
        if let model = stringValue(payload["model"]), !model.isEmpty {
            return model
        }
        for key in ["thread_settings", "settings"] {
            if let nested = dictionaryValue(payload[key]),
               let model = stringValue(nested["model"]),
               !model.isEmpty {
                return model
            }
        }
        if let collaboration = dictionaryValue(payload["collaboration_mode"]),
           let settings = dictionaryValue(collaboration["settings"]),
           let model = stringValue(settings["model"]),
           !model.isEmpty {
            return model
        }
        return nil
    }

    private static func hasServiceTierSetting(_ payload: [String: Any]) -> Bool {
        if payload.keys.contains("service_tier") || payload.keys.contains("serviceTier") { return true }
        for key in ["thread_settings", "settings", "collaboration_mode"] {
            if let nested = dictionaryValue(payload[key]), hasServiceTierSetting(nested) { return true }
        }
        return false
    }

    private static func serviceTierFromPayload(_ payload: [String: Any]) -> String? {
        for key in ["service_tier", "serviceTier"] {
            if let tier = stringValue(payload[key]), !tier.isEmpty { return tier }
        }
        for key in ["thread_settings", "settings"] {
            if let nested = dictionaryValue(payload[key]), let tier = serviceTierFromPayload(nested) { return tier }
        }
        if let collaboration = dictionaryValue(payload["collaboration_mode"]),
           let settings = dictionaryValue(collaboration["settings"]) {
            return serviceTierFromPayload(settings)
        }
        return nil
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
            cacheWriteInputTokens: max(previous.cacheWriteInputTokens, current.cacheWriteInputTokens),
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
            cacheWriteInputTokens: current.cacheWriteInputTokens >= previous.cacheWriteInputTokens ? current.cacheWriteInputTokens - previous.cacheWriteInputTokens : (sameSession ? 0 : current.cacheWriteInputTokens),
            outputTokens: current.outputTokens >= previous.outputTokens ? current.outputTokens - previous.outputTokens : (sameSession ? 0 : current.outputTokens),
            reasoningOutputTokens: current.reasoningOutputTokens >= previous.reasoningOutputTokens ? current.reasoningOutputTokens - previous.reasoningOutputTokens : (sameSession ? 0 : current.reasoningOutputTokens),
            totalTokens: current.totalTokens >= previous.totalTokens ? current.totalTokens - previous.totalTokens : (sameSession ? 0 : current.totalTokens)
        )
        return delta.inputTokens > 0
            || delta.cachedInputTokens > 0
            || delta.cacheWriteInputTokens > 0
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
                "description": "Read Codex rate limits, local token usage, daily API-equivalent cost, estimated Codex credits, official credit balance when available, and the local weekly quota value estimate.",
                "inputSchema": emptyInputSchema(),
            ],
            [
                "name": "get_codex_rate_limits",
                "description": "Read the current Codex weekly rate-limit snapshot.",
                "inputSchema": emptyInputSchema(),
            ],
            [
                "name": "get_codex_local_usage",
                "description": "Read today's local Codex token usage, API-equivalent cost and token-based credit estimates with pricing coverage from desktop and CLI session logs. Credit estimates are not actual deductions.",
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
                try writeJSON(CodexBackend.readLocalTokenUsage(rebuild: arguments.dropFirst().contains("--rebuild")))
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
