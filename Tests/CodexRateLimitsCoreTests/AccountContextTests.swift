import Foundation
import XCTest
@testable import CodexRateLimitsCore

final class AccountContextTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AccountContextTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func login(_ home: URL, account: String = "workspace-a", user: String = "user-a",
                       accessToken: String = "test-access") throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let claims = try JSONSerialization.data(withJSONObject: ["sub": user, "email": "test@example.invalid"])
        let encoded = claims.base64EncodedString().replacingOccurrences(of: "=", with: "")
        let object: [String: Any] = ["tokens": ["account_id": account, "id_token": "header.\(encoded).signature",
                                                 "access_token": accessToken]]
        try JSONSerialization.data(withJSONObject: object).write(to: home.appendingPathComponent("auth.json"))
    }

    private func source(_ home: URL) -> CodexAccountSource {
        CodexAccountSource(environment: ["CODEX_HOME": home.path], home: directory)
    }

    private var serverAccount: [String: Any] { ["type": "chatgpt", "email": "test@example.invalid", "planType": "pro"] }

    private func context(_ key: String, limitID: String = "codex", home: String = "/tmp/home") -> CodexAccountContext {
        CodexAccountContext(codexHome: home, authenticationSource: home + "/auth.json", accountKey: key,
                            accountLabel: nil, limitID: limitID)
    }

    func testSourceUsesActiveHomeAndDoesNotRedirectOnlyResetAuthentication() throws {
        let desktop = directory.appendingPathComponent(".codex")
        let cli = directory.appendingPathComponent(".codex-cli")
        try login(desktop)
        try login(cli, account: "workspace-b")
        let selected = CodexAccountSource(environment: ["CODEX_HOME": cli.path,
                                                        "CODEX_AUTH_FILE": desktop.appendingPathComponent("auth.json").path], home: directory)
        XCTAssertEqual(selected.authFile, cli.appendingPathComponent("auth.json").resolvingSymlinksInPath())
        XCTAssertNotEqual(selected.identityKey, source(desktop).identityKey)
        let fallback = CodexAccountSource(environment: [:], home: directory)
        XCTAssertEqual(fallback.identityKey, source(desktop).identityKey)
    }

    func testIdentityDistinguishesUsersAndWorkspacesButSurvivesTokenRefresh() throws {
        try login(directory)
        let original = source(directory).identityKey
        XCTAssertNotNil(original)
        try login(directory, accessToken: "refreshed-token")
        XCTAssertEqual(original, source(directory).identityKey)
        try login(directory, user: "user-b")
        XCTAssertNotEqual(original, source(directory).identityKey)
        try login(directory, account: "workspace-b")
        XCTAssertNotEqual(original, source(directory).identityKey)
        let context = source(directory).context(account: serverAccount)
        let encoded = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
        XCTAssertFalse(encoded.contains("test-access"))
        XCTAssertFalse(encoded.contains("header."))
    }

    func testMissingOrUnverifiedCredentialsNeverAcquirePersistentIdentity() throws {
        XCTAssertNil(source(directory).context(account: serverAccount).scopeKey)
        try login(directory)
        XCTAssertNil(source(directory).context(account: ["type": "chatgpt", "email": "different@example.invalid"]).scopeKey)
        XCTAssertNil(source(directory).context(account: nil).scopeKey)
        try Data("cli_auth_credentials_store = \"keyring\"\n".utf8).write(to: directory.appendingPathComponent("config.toml"))
        XCTAssertNil(source(directory).context(account: serverAccount).scopeKey)
    }

    func testOfficialResetCountIsAuthoritativeAndNullDetailsAreNotZero() throws {
        let onlyCount = CodexBackend.normalizeResetCreditsResponse(["availableCount": 3, "credits": NSNull()])
        XCTAssertEqual(onlyCount.availableCount, 3)
        XCTAssertEqual(onlyCount.detailsAvailable, false)
        XCTAssertTrue(onlyCount.credits.isEmpty)
        XCTAssertEqual(onlyCount.display?.detailLabels, [AppText.resetCreditDetailsUnavailable])
        let empty = CodexBackend.normalizeResetCreditsResponse(["availableCount": 0, "credits": []])
        XCTAssertEqual(empty.availableCount, 0)
        XCTAssertEqual(empty.detailsAvailable, true)
        let capped = CodexBackend.normalizeResetCreditsResponse(["availableCount": 5, "credits": [
            ["id": "credit-a", "resetType": "codexRateLimits", "status": "available", "grantedAt": 1_800_000_000, "expiresAt": 1_800_086_400]
        ]])
        XCTAssertEqual(capped.availableCount, 5)
        XCTAssertEqual(capped.credits.first?.resetType, "codexRateLimits")
        XCTAssertNotNil(capped.credits.first?.createdAtIso)
        XCTAssertNotNil(capped.credits.first?.expiresAtIso)
        XCTAssertNil(CodexBackend.normalizeResetCreditsResponse([:]).availableCount)
    }

    func testOfficialResetDataAvoidsPrivateRequestAndFallbackUsesSameAccount() throws {
        try login(directory)
        let source = source(directory)
        let context = source.context(account: serverAccount)
        var calls = 0
        let official = CodexBackend.resolveResetCredits(response: ["rateLimitResetCredits": ["availableCount": 2, "credits": NSNull()]],
                                                        source: source, context: context) { _ in
            calls += 1
            return Data()
        }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(official.availableCount, 2)
        let fallback = CodexBackend.resolveResetCredits(response: [:], source: source, context: context) { request in
            calls += 1
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-ID"), "workspace-a")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access")
            return Data(#"{"available_count":4,"credits":[]}"#.utf8)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(fallback.availableCount, 4)
        XCTAssertEqual(fallback.accountContext?.scopeKey, context.scopeKey)
        let rejected = CodexBackend.resolveResetCredits(response: [:], source: source, context: self.context("other")) { _ in
            XCTFail("Must not send credentials for a different account")
            return Data()
        }
        XCTAssertNotNil(rejected.error)
    }

    func testAccountRequestPinsHomeSelectsCodexBucketAndRejectsSwitchDuringRefresh() throws {
        try login(directory)
        let response: [String: Any] = [
            "account/read": ["account": serverAccount],
            "account/rateLimits/read": ["rateLimits": ["limitId": "other"],
                                        "rateLimitsByLimitId": ["codex": ["limitId": "codex", "secondary": ["usedPercent": 25, "windowDurationMins": 10080]]],
                                        "rateLimitResetCredits": ["availableCount": 0, "credits": []]]
        ]
        let payload = try CodexBackend.readAccountPayload(includeUsage: false, sourceProvider: { self.source(self.directory) }, call: { methods, home in
            XCTAssertEqual(methods, ["account/read", "account/rateLimits/read"])
            XCTAssertEqual(home, self.directory.resolvingSymlinksInPath().path)
            return response
        }, fetchReset: { _ in XCTFail("Official reset data should be reused"); return Data() })
        XCTAssertEqual(payload.selectedRateLimit?.weeklyWindow?.remainingPercent, 75)
        XCTAssertEqual(payload.accountContext?.limitID, "codex")
        XCTAssertNotNil(payload.accountContext?.scopeKey)
        XCTAssertThrowsError(try CodexBackend.readAccountPayload(includeUsage: false, sourceProvider: { self.source(self.directory) }, call: { _, _ in
            try self.login(self.directory, account: "workspace-b")
            return response
        }))
    }

    func testQuotaHistoryAndNotificationsAreIsolatedAndRestoredByScope() throws {
        let base = directory.appendingPathComponent("history.json")
        let monitor = QuotaMonitor(fileURL: base)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func window(_ remaining: Int, shift: TimeInterval = 0) -> RateLimitWindow {
            RateLimitWindow(usedPercent: 100 - remaining, remainingPercent: remaining, windowDurationMins: 10080,
                            resetsAt: Int(now.addingTimeInterval(3 * 86400 + shift).timeIntervalSince1970), resetsAtIso: nil)
        }
        let a = context("a"), b = context("b")
        _ = monitor.update(window: window(95), at: now.addingTimeInterval(-7200), alertsEnabled: false, accountContext: a)
        let first = monitor.update(window: window(20), at: now, alertsEnabled: true, accountContext: a)
        XCTAssertEqual(first.sampleCount, 2)
        XCTAssertEqual(first.alerts.map(\.kind), [.warning])
        let second = monitor.update(window: window(20, shift: -2 * 86400), at: now, alertsEnabled: true, accountContext: b)
        XCTAssertEqual(second.sampleCount, 1)
        XCTAssertEqual(second.forecast?.basis, .windowAverage)
        XCTAssertEqual(second.alerts.map(\.kind), [.warning])
        XCTAssertNotEqual(first.alerts.first?.identifier, second.alerts.first?.identifier)
        let restored = monitor.update(window: window(20, shift: 600), at: now, alertsEnabled: true, accountContext: a)
        XCTAssertEqual(restored.sampleCount, 2)
        XCTAssertEqual(restored.forecast?.basis, .recentTrend)
        XCTAssertTrue(restored.alerts.isEmpty)
        for scope in [context("a", limitID: "spark"), context("a", home: "/tmp/other-home")] {
            let separate = monitor.update(window: window(20), at: now, alertsEnabled: true, accountContext: scope)
            XCTAssertEqual(separate.sampleCount, 1)
            XCTAssertEqual(separate.alerts.map(\.kind), [.warning])
        }
        let restarted = QuotaMonitor(fileURL: base).update(window: window(20, shift: 600), at: now, alertsEnabled: true, accountContext: a)
        XCTAssertEqual(restarted.sampleCount, 2)
        XCTAssertTrue(restarted.alerts.isEmpty)
    }

    func testLegacyQuotaHistoryIsPreservedButNotAssignedToAnAccount() throws {
        let file = directory.appendingPathComponent("history.json")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = RateLimitWindow(usedPercent: 80, remainingPercent: 20, windowDurationMins: 10080,
                                     resetsAt: Int(now.timeIntervalSince1970) + 86400, resetsAtIso: nil)
        _ = QuotaMonitor(fileURL: file).update(window: window, at: now, alertsEnabled: true)
        let legacy = try Data(contentsOf: file)
        let current = QuotaMonitor(fileURL: file).update(window: window, at: now, alertsEnabled: true, accountContext: context("new"))
        XCTAssertEqual(current.alerts.map(\.kind), [.warning])
        XCTAssertEqual(try Data(contentsOf: file), legacy)
        let unknown = CodexAccountContext(codexHome: "/tmp", authenticationSource: "/tmp/auth.json", accountKey: nil,
                                          accountLabel: nil, limitID: "codex")
        let result = QuotaMonitor(fileURL: file).update(window: window, at: now, alertsEnabled: true, accountContext: unknown)
        XCTAssertEqual(result.sampleCount, 0)
        XCTAssertTrue(result.alerts.isEmpty)
    }
}
