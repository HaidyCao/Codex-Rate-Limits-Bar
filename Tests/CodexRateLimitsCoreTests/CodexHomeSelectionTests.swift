import Foundation
import XCTest
@testable import CodexRateLimitsCore

final class CodexHomeSelectionTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    private func profile(_ name: String) throws -> URL {
        let url = home.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try Data("fixture configuration".utf8).write(to: url.appendingPathComponent("config.toml"))
        try Data("{invalid auth must not be read}".utf8).write(to: url.appendingPathComponent("auth.json"))
        return url
    }

    private func writeUsage(_ folder: URL, id: String, tokens: Int, at date: Date, append: Bool = false) throws {
        var records: [[String: Any]] = append ? [] : [
            ["type": "session_meta", "payload": ["id": id]],
            ["type": "turn_context", "payload": ["model": "gpt-6.1-sol", "service_tier": "standard"]]
        ]
        records.append(["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: date), "payload": ["type": "token_count", "info": [
            "total_token_usage": ["input_tokens": tokens, "total_tokens": tokens], "last_token_usage": ["input_tokens": tokens]]]])
        let file = folder.appendingPathComponent("sessions/\(id).jsonl")
        var raw = append ? try Data(contentsOf: file) : Data()
        for record in records { raw.append(try JSONSerialization.data(withJSONObject: record)); raw.append(10) }
        try raw.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    func testDiscoveryFindsImmediateProfilesWithoutRecursingOrReadingCredentials() throws {
        let desktop = try profile(".codex")
        let third = try profile(".codex-3")
        let cli = try profile(".codex-cli")
        let custom = try profile("work-profile")
        _ = try profile("nested/deeper-codex")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("codex-project"), withIntermediateDirectories: true)
        let candidates = CodexHomeDiscovery.discover(home: home)
        XCTAssertEqual(candidates.first?.path, CodexPaths.canonical(desktop).path)
        XCTAssertEqual(Set(candidates.map(\.path)), Set([desktop, third, cli, custom].map { CodexPaths.canonical($0).path }))
        XCTAssertTrue(candidates.allSatisfy { $0.hasAuthentication && $0.hasConfiguration && $0.hasSessions })
        XCTAssertTrue(candidates.allSatisfy { $0.displayPath(home: home).hasPrefix("~/") })
    }

    func testAliasesAreDeduplicatedAndMissingSelectedHomesStayVisible() throws {
        let original = try profile(".codex")
        let alias = home.appendingPathComponent(".codex-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        let missing = home.appendingPathComponent("removed-profile")
        let candidates = CodexHomeDiscovery.discover(home: home, including: [missing.path, alias.path])
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates.first?.path, CodexPaths.canonical(original).path)
        XCTAssertFalse(try XCTUnwrap(candidates.first { $0.path == CodexPaths.canonical(missing).path }).isAvailable)
    }

    func testInitialDesktopChoiceAndExplicitRootsOverrideCLIEnvironment() throws {
        let desktop = try profile(".codex")
        let cli = try profile(".codex-cli")
        let third = try profile(".codex-3")
        let initial = CodexHomeSelection.initial(home: home)
        XCTAssertEqual(initial.activeHome, CodexPaths.canonical(desktop).path)
        XCTAssertEqual(Set(initial.localHomes), Set([desktop, cli, third].map { CodexPaths.canonical($0).path }))
        let chosen = CodexHomeSelection(activeHome: third, localHomes: [desktop, desktop])
        XCTAssertEqual(chosen.localHomes.count, 2)
        XCTAssertEqual(UsageRefreshServices.live(selection: chosen).localHomeCount, 2)
        let env = chosen.environment(overriding: ["CODEX_HOME": cli.path, "CODEX_SESSIONS_DIR": "/wrong", "PATH": "/bin"])
        XCTAssertEqual(env["CODEX_HOME"], chosen.activeHome)
        XCTAssertNil(env["CODEX_SESSIONS_DIR"])
        XCTAssertEqual(env["PATH"], "/bin")
        XCTAssertEqual(chosen.weeklyRoots.map(\.lastPathComponent), ["sessions", "archived_sessions"])
        XCTAssertTrue(chosen.weeklyRoots.allSatisfy { $0.path.hasPrefix(chosen.activeHome + "/") })
        XCTAssertEqual(chosen.localRoots.count, 4)
        XCTAssertNotEqual(initial.identity, chosen.identity)
        XCTAssertEqual(chosen, try JSONDecoder().decode(CodexHomeSelection.self, from: JSONEncoder().encode(chosen)).validated())
    }

    func testSelectedSessionsUseTheirOwnCacheAndOnlyChosenDailyRoots() throws {
        let desktop = try profile(".codex")
        let cli = try profile(".codex-cli")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        try writeUsage(desktop, id: "desktop", tokens: 100, at: date)
        try writeUsage(cli, id: "cli", tokens: 900, at: date)
        let desktopSelection = CodexHomeSelection(activeHome: desktop, localHomes: [desktop])
        let cliSelection = CodexHomeSelection(activeHome: cli, localHomes: [cli])
        func session(_ selection: CodexHomeSelection) -> SelectedCodexSession {
            SelectedCodexSession(selection: selection, environment: ["CODEX_HOME": cli.path], home: home,
                monitor: QuotaMonitor(fileURL: home.appendingPathComponent("history.json")), now: { date }, calendar: calendar)
        }
        let request = LocalUsageRequest(weeklyWindow: nil, accountContext: nil, quotaSampleAt: nil, rebuild: false)
        let first = try session(desktopSelection).local(request, cancellation: RefreshCancellation(deadline: .distantFuture))
        let second = try session(cliSelection).local(request, cancellation: RefreshCancellation(deadline: .distantFuture))
        XCTAssertEqual(first.totalTokens, 100)
        XCTAssertEqual(second.totalTokens, 900)
        XCTAssertEqual(first.todayCost?.estimatedCostUSD ?? -1, 0.0002, accuracy: 1e-12)
        XCTAssertEqual(second.todayCost?.estimatedCostUSD ?? -1, 0.0018, accuracy: 1e-12)
        XCTAssertEqual(try session(desktopSelection).local(request, cancellation: RefreshCancellation(deadline: .distantFuture)).totalTokens, 100)
        let firstCache = LocalUsagePaths.localUsageCacheURL(environment: desktopSelection.environment(overriding: [:]), home: home)
        let secondCache = LocalUsagePaths.localUsageCacheURL(environment: cliSelection.environment(overriding: [:]), home: home)
        XCTAssertNotEqual(firstCache, secondCache)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(firstCache).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(secondCache).path))
    }

    func testRemovingDailyHomePreservesActiveWeeklyObservationAcrossRestartAndRebuild() throws {
        let desktop = try profile(".codex")
        let cli = try profile(".codex-cli")
        let copy = try profile(".codex-copy")
        let claims = try JSONSerialization.data(withJSONObject: ["sub": "fixture-user", "email": "fixture@example.invalid"])
        let encoded = claims.base64EncodedString().replacingOccurrences(of: "=", with: "")
        let auth: [String: Any] = ["tokens": ["account_id": "fixture-account", "id_token": "header.\(encoded).signature", "access_token": "fixture-token"]]
        try JSONSerialization.data(withJSONObject: auth).write(to: desktop.appendingPathComponent("auth.json"))
        let context = CodexAccountSource(environment: ["CODEX_HOME": desktop.path], home: home)
            .context(account: ["type": "chatgpt", "email": "fixture@example.invalid"])
        XCTAssertNotNil(context.scopeKey)
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = Int(date.addingTimeInterval(86_400).timeIntervalSince1970)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        try writeUsage(desktop, id: "desktop", tokens: 100, at: date.addingTimeInterval(-60))
        try writeUsage(cli, id: "cli", tokens: 900, at: date.addingTimeInterval(-60))
        try writeUsage(copy, id: "desktop", tokens: 100, at: date.addingTimeInterval(-60))
        let all = CodexHomeSelection(activeHome: desktop, localHomes: [desktop, cli, copy])
        let onlyDesktop = CodexHomeSelection(activeHome: desktop, localHomes: [desktop])
        func session(_ selection: CodexHomeSelection) -> SelectedCodexSession {
            SelectedCodexSession(selection: selection, environment: ["CODEX_HOME": cli.path], home: home,
                monitor: QuotaMonitor(fileURL: home.appendingPathComponent("history.json")), now: { date }, calendar: calendar)
        }
        func request(_ used: Int, rebuild: Bool = false) -> LocalUsageRequest {
            LocalUsageRequest(weeklyWindow: RateLimitWindow(usedPercent: used, remainingPercent: 100 - used,
                windowDurationMins: 10_080, resetsAt: reset, resetsAtIso: nil), accountContext: context,
                quotaSampleAt: date, rebuild: rebuild)
        }
        func read(_ session: SelectedCodexSession, _ request: LocalUsageRequest) throws -> LocalUsageSnapshot {
            try session.local(request, cancellation: RefreshCancellation(deadline: .distantFuture))
        }
        let original = session(all)
        let baseline = try read(original, request(20))
        XCTAssertEqual(baseline.totalTokens, 1_000)
        date.addTimeInterval(60)
        try writeUsage(desktop, id: "desktop", tokens: 200, at: date, append: true)
        try Data(contentsOf: desktop.appendingPathComponent("sessions/desktop.jsonl"))
            .write(to: copy.appendingPathComponent("sessions/desktop.jsonl"))
        try writeUsage(copy, id: "desktop", tokens: 300, at: date, append: true)
        let observed = try read(original, request(21))
        XCTAssertEqual(observed.totalTokens, 1_200)
        XCTAssertEqual(try XCTUnwrap(observed.weeklyQuotaCost?.observedCostUSD), 0.0002, accuracy: 1e-12)
        let cacheURL = try XCTUnwrap(LocalUsagePaths.localUsageCacheURL(environment: all.environment(overriding: [:]), home: home))
        let oldCache = try JSONDecoder().decode(LocalUsageCacheDocument.self, from: Data(contentsOf: cacheURL))
        for rebuild in [false, true, false] {
            let reduced = try read(session(onlyDesktop), request(21, rebuild: rebuild))
            XCTAssertEqual(reduced.totalTokens, 200)
            XCTAssertEqual(try XCTUnwrap(reduced.todayCost?.estimatedCostUSD), 0.0004, accuracy: 1e-12)
            XCTAssertEqual(try XCTUnwrap(reduced.weeklyQuotaCost?.observedCostUSD), 0.0002, accuracy: 1e-12)
            XCTAssertEqual(reduced.weeklyQuotaCost?.observationStartIso, baseline.weeklyQuotaCost?.observationStartIso)
            XCTAssertEqual(reduced.diagnostics?.status, .complete)
        }
        let newCache = try JSONDecoder().decode(LocalUsageCacheDocument.self, from: Data(contentsOf: cacheURL))
        XCTAssertEqual(newCache.cache.weeklyCostObservation?.startedAt, oldCache.cache.weeklyCostObservation?.startedAt)
        XCTAssertEqual(newCache.cache.weeklyCostObservation?.history?.samples.count, oldCache.cache.weeklyCostObservation?.history?.samples.count)
        XCTAssertTrue(newCache.cache.files.keys.allSatisfy { $0.hasPrefix(CodexPaths.canonical(desktop).path + "/") })
    }
}
