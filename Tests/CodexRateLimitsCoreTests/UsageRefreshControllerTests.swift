import Foundation
import XCTest
@testable import CodexRateLimitsCore

@MainActor
final class UsageRefreshControllerTests: XCTestCase {
    func testSleepBeforeCompletionLeavesUndeliveredAlertRetryable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let h = Harness(monitor: QuotaMonitor(fileURL: directory.appendingPathComponent("history.json")))
        h.stub.change { $0.remaining = 25 }
        var alerts: [QuotaAlertEvent] = []
        h.controller.alertsEnabled = true
        h.controller.onQuotaAlert = { request, _ in alerts.append(request.event) }
        h.controller.refreshOfficial()
        XCTAssertTrue(h.executor.run(.official))
        h.controller.sleep()
        await h.flushCompletions()
        XCTAssertTrue(alerts.isEmpty)
        h.controller.wake()
        try await h.complete(.official)
        XCTAssertEqual(alerts.map(\.kind), [.warning])
    }

    func testDisablingAlertsBeforeCompletionPreventsSubmission() async throws {
        let h = Harness()
        var alerts = 0
        h.controller.alertsEnabled = true
        h.controller.onQuotaAlert = { _, _ in alerts += 1 }
        h.controller.refreshOfficial()
        XCTAssertTrue(h.executor.run(.official))
        h.controller.alertsEnabled = false
        await h.flushCompletions()
        XCTAssertEqual(alerts, 0)
        h.controller.alertsEnabled = true
        h.controller.refreshOfficial()
        try await h.complete(.official)
        XCTAssertEqual(alerts, 1)
    }

    func testRejectedSubmissionRetriesAndAcceptedSubmissionPersistsDedupe() async throws {
        let h = Harness(realHistory: true)
        h.stub.change { $0.remaining = 25 }
        h.controller.alertsEnabled = true
        h.controller.refreshOfficial()
        try await h.complete(.official)
        h.controller.refreshOfficial()
        try await h.complete(.official)
        XCTAssertEqual(h.alerts.requests.count, 1, "Repeated refresh must not submit while add is pending")
        h.alerts.finish(0, error: "Notifications unavailable")
        XCTAssertEqual(h.controller.state.quotaAlertError, "Notifications unavailable")
        h.controller.refreshOfficial()
        try await h.complete(.official)
        XCTAssertEqual(h.alerts.requests.count, 2)
        h.alerts.finish(1)
        h.alerts.finish(1) // A duplicate callback cannot enqueue a second acknowledgement.
        XCTAssertEqual(h.executor.count(.official), 1)
        try await h.complete(.official) // Persist acknowledgement on the worker queue.
        XCTAssertNil(h.controller.state.quotaAlertError)
        h.controller.refreshOfficial()
        try await h.complete(.official)
        XCTAssertEqual(h.alerts.requests.count, 2)
        XCTAssertEqual(h.stub.acknowledgements.count, 1)
        let window = try XCTUnwrap(h.controller.state.weeklyWindow)
        let restarted = QuotaMonitor(fileURL: h.historyURL).update(window: window, at: h.stub.settings.now,
            alertsEnabled: true, accountContext: h.controller.state.accountContext)
        XCTAssertTrue(restarted.alerts.isEmpty)
    }

    func testDisabledInFlightSubmissionCannotAcknowledgeOrCancelNewAttempt() async throws {
        let h = Harness(realHistory: true)
        h.stub.change { $0.remaining = 25 }
        h.controller.alertsEnabled = true
        h.controller.refreshOfficial()
        try await h.complete(.official)
        h.controller.alertsEnabled = false
        XCTAssertEqual(h.alerts.cancelled, [h.alerts.requests[0].identifier])
        h.controller.alertsEnabled = true
        h.controller.refreshOfficial()
        try await h.complete(.official)
        XCTAssertEqual(h.alerts.requests.count, 2)
        XCTAssertNotEqual(h.alerts.requests[0].identifier, h.alerts.requests[1].identifier)
        h.alerts.finish(0, error: "Stale failure")
        XCTAssertNil(h.controller.state.quotaAlertError)
        XCTAssertEqual(h.executor.count(.official), 0)
        XCTAssertFalse(h.alerts.cancelled.contains(h.alerts.requests[1].identifier))
        h.alerts.finish(1)
        try await h.complete(.official)
        XCTAssertEqual(h.stub.acknowledgements.count, 1)
    }

    func testAccountSwitchRejectsLateConfirmationAndKeepsBothAccountsRetryable() async throws {
        let h = Harness(realHistory: true)
        h.stub.change { $0.remaining = 25 }
        h.controller.alertsEnabled = true
        h.controller.refreshOfficial()
        try await h.complete(.official)
        h.stub.change { $0.account = "b" }
        h.alerts.finish(0)
        XCTAssertTrue(h.stub.acknowledgements.isEmpty)
        XCTAssertNil(h.controller.state.accountContext)
        h.controller.refreshOfficial()
        try await h.complete(.official)
        XCTAssertEqual(h.alerts.requests.count, 2)
        XCTAssertNotEqual(h.alerts.requests[0].event.accountScopeKey, h.alerts.requests[1].event.accountScopeKey)
        h.alerts.finish(1)
        try await h.complete(.official)
        h.stub.change { $0.account = "a" }
        h.controller.refreshOfficial()
        try await h.complete(.official)
        XCTAssertEqual(h.alerts.requests.count, 3)
        XCTAssertEqual(h.alerts.requests[2].event.accountScopeKey, h.alerts.requests[0].event.accountScopeKey)
    }

    func testServerContextChangeRejectsOldNotificationCallback() async throws {
        let h = Harness(realHistory: true)
        h.stub.change { $0.remaining = 25 }
        h.controller.alertsEnabled = true
        h.controller.refreshOfficial()
        try await h.complete(.official)
        h.stub.change { $0.serverAccount = "b" }
        h.controller.refreshOfficial()
        try await h.complete(.official)
        h.alerts.finish(0)
        XCTAssertTrue(h.stub.acknowledgements.isEmpty)
        XCTAssertEqual(h.alerts.requests.count, 2)
        h.alerts.finish(1)
        try await h.complete(.official)
        XCTAssertEqual(h.stub.acknowledgements.map(\.accountScopeKey), [h.controller.state.accountContext?.scopeKey])
    }

    func testSleepAndStopCancelInFlightNotificationsWithoutAcknowledging() async throws {
        let h = Harness(realHistory: true)
        h.stub.change { $0.remaining = 25 }
        h.controller.alertsEnabled = true
        h.controller.refreshOfficial()
        try await h.complete(.official)
        h.controller.sleep()
        h.alerts.finish(0)
        XCTAssertTrue(h.stub.acknowledgements.isEmpty)
        h.controller.wake()
        try await h.complete(.official)
        XCTAssertEqual(h.alerts.requests.count, 2)
        h.controller.stop()
        h.alerts.finish(1)
        XCTAssertTrue(h.stub.acknowledgements.isEmpty)
        XCTAssertTrue(h.alerts.requests.allSatisfy { h.alerts.cancelled.contains($0.identifier) })
    }

    func testMissingNotificationCallbackTimesOutAndLateReplyDoesNotAcknowledge() async throws {
        let h = Harness(realHistory: true)
        h.stub.change { $0.remaining = 25 }
        h.controller.alertsEnabled = true
        h.controller.refreshOfficial()
        try await h.complete(.official)
        h.stub.change { $0.now.addTimeInterval(46) }
        h.controller.heartbeat()
        h.alerts.finish(0)
        XCTAssertTrue(h.stub.acknowledgements.isEmpty)
        h.controller.refreshOfficial()
        try await h.complete(.official)
        XCTAssertEqual(h.alerts.requests.count, 2)
    }

    func testQuotaRecoveryAndNewWindowCancelObsoleteNotifications() async throws {
        let h = Harness(realHistory: true)
        h.stub.change { $0.remaining = 25 }
        h.controller.alertsEnabled = true
        h.controller.refreshOfficial()
        try await h.complete(.official)
        h.stub.change { $0.remaining = 100 }
        h.controller.refreshOfficial()
        try await h.complete(.official)
        h.alerts.finish(0)
        XCTAssertTrue(h.stub.acknowledgements.isEmpty)
        XCTAssertEqual(h.alerts.requests.count, 1)
        h.stub.change { $0.remaining = 25 }
        h.controller.refreshOfficial()
        try await h.complete(.official)
        h.stub.change { $0.resetAt += 604800 }
        h.controller.refreshOfficial()
        try await h.complete(.official)
        h.alerts.finish(1)
        XCTAssertTrue(h.stub.acknowledgements.isEmpty)
        h.alerts.finish(2)
        try await h.complete(.official)
        XCTAssertEqual(h.stub.acknowledgements.map(\.windowID), [h.alerts.requests[2].event.windowID])
    }

    func testAccountIsRecheckedBeforeAcknowledgementWorkerWritesHistory() async throws {
        let h = Harness(realHistory: true)
        h.stub.change { $0.remaining = 25 }
        h.controller.alertsEnabled = true
        h.controller.refreshOfficial()
        try await h.complete(.official)
        h.alerts.finish(0)
        h.stub.change { $0.account = "b" }
        try await h.complete(.official)
        XCTAssertTrue(h.stub.acknowledgements.isEmpty)
        XCTAssertNil(h.controller.state.accountContext)
    }

    func testSleepAfterAcceptanceDoesNotRemoveNotificationWhileReceiptIsSaving() async throws {
        let h = Harness(realHistory: true)
        h.stub.change { $0.remaining = 25 }
        h.controller.alertsEnabled = true
        h.controller.refreshOfficial()
        try await h.complete(.official)
        h.alerts.finish(0)
        h.controller.sleep()
        XCTAssertTrue(h.alerts.cancelled.isEmpty)
        try await h.complete(.official) // Accepted receipt can finish saving during sleep.
        XCTAssertEqual(h.stub.acknowledgements.count, 1)
        h.controller.wake()
        try await h.complete(.official)
        XCTAssertEqual(h.alerts.requests.count, 1)
    }

    func testFailureRetainsSameAccountDataAndLocalSuccessCannotClearOfficialError() async throws {
        let h = Harness()
        h.controller.refreshOfficial()
        try await h.complete(.official)
        try await h.complete(.local)
        let succeeded = h.controller.freshness.quota.lastSuccessAtIso
        h.stub.change { $0.now.addTimeInterval(10); $0.officialError = "  Offline\t\n request failed  " }
        h.controller.refreshOfficial()
        try await h.complete(.official)
        XCTAssertEqual(h.controller.state.weeklyRemaining, 75)
        XCTAssertEqual(h.controller.state.credits?.balance, "12.5")
        XCTAssertEqual(h.controller.freshness.quota.lastSuccessAtIso, succeeded)
        XCTAssertEqual(h.controller.freshness.quota.error, "Offline\nrequest failed")
        h.stub.change { $0.tokens = 200 }
        h.controller.refreshLocal()
        try await h.complete(.local)
        XCTAssertEqual(h.controller.state.localUsage?.totalTokens, 200)
        XCTAssertEqual(h.controller.freshness.localUsage.status, .success)
        XCTAssertEqual(h.controller.freshness.quota.error, "Offline\nrequest failed")
        h.stub.change { $0.officialError = nil; $0.balance = "8" }
        h.controller.refreshOfficial()
        try await h.complete(.official)
        XCTAssertEqual(h.controller.state.credits?.balance, "8")
        XCTAssertNil(h.controller.freshness.quota.error)
    }

    func testMissingFieldsClearValuesButResetFailureRetainsSameAccountCount() async throws {
        let h = Harness()
        h.controller.refreshOfficial()
        try await h.complete(.official)
        h.stub.change { $0.balance = nil; $0.resetError = "Reset failed"; $0.hasQuota = false }
        h.controller.refreshOfficial()
        try await h.complete(.official)
        XCTAssertNil(h.controller.state.weeklyWindow)
        XCTAssertNil(h.controller.state.credits)
        XCTAssertEqual(h.controller.state.resetAvailableCount, 3)
        XCTAssertEqual(h.controller.freshness.quota.status, .unavailable)
        XCTAssertEqual(h.controller.freshness.credits.status, .unavailable)
        XCTAssertEqual(h.controller.freshness.resetCredits.error, "Reset failed")
    }

    func testAccountChangeBetweenWorkerAndCompletionDiscardsDataAndAlerts() async throws {
        let h = Harness()
        var alerts: [QuotaAlertEvent] = []
        h.controller.alertsEnabled = true
        h.controller.onQuotaAlert = { request, _ in alerts.append(request.event) }
        h.controller.refreshOfficial()
        XCTAssertTrue(h.executor.run(.official)) // Completion is queued, not delivered yet.
        h.stub.change { $0.account = "b"; $0.balance = "99" }
        await h.flushCompletions()
        XCTAssertNil(h.controller.state.accountContext)
        XCTAssertNil(h.controller.state.credits)
        XCTAssertTrue(alerts.isEmpty)
        XCTAssertEqual(h.executor.count(.official), 1)
        try await h.complete(.official)
        XCTAssertEqual(h.controller.state.accountContext?.accountKey, "b")
        XCTAssertEqual(h.controller.state.credits?.balance, "99")
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.accountScopeKey, h.controller.state.accountContext?.scopeKey)
    }

    func testServerContextChangeClearsOldLocalDataAndResetCount() async throws {
        let h = Harness()
        h.controller.refreshOfficial()
        try await h.complete(.official)
        try await h.complete(.local)
        h.controller.refreshLocal()
        XCTAssertTrue(h.executor.run(.local))
        await h.flushCompletions()
        XCTAssertNotNil(h.controller.state.localUsage)
        h.stub.change { $0.serverAccount = "different-server-scope"; $0.resetError = "Reset failed" }
        // The local file identity stays unchanged, but the server reports a new context.
        h.controller.refreshOfficial()
        try await h.complete(.official)
        XCTAssertNil(h.controller.state.localUsage)
        XCTAssertNil(h.controller.state.resetAvailableCount)
        XCTAssertNil(h.controller.freshness.resetCredits.lastSuccessAtIso)
        XCTAssertEqual(h.controller.state.accountContext?.accountKey, "different-server-scope")
        try await h.complete(.local)
        XCTAssertEqual(h.stub.requests.last?.accountContext?.accountKey, "different-server-scope")
    }

    func testNewOfficialContextInvalidatesInFlightLocalSnapshot() async throws {
        let h = Harness()
        h.controller.refreshOfficial()
        try await h.complete(.official)
        // Local work now holds context a; leave its completion queued behind the new official result.
        h.stub.change { $0.serverAccount = "b"; $0.tokens = 900 }
        h.controller.refreshOfficial()
        XCTAssertTrue(h.executor.run(.official))
        XCTAssertTrue(h.executor.run(.local))
        await h.flushCompletions()
        XCTAssertEqual(h.controller.state.accountContext?.accountKey, "b")
        XCTAssertNil(h.controller.state.localUsage)
        XCTAssertEqual(h.executor.count(.local), 1)
        try await h.complete(.local)
        XCTAssertEqual(h.controller.state.localUsage?.accountContext?.accountKey, "b")
        XCTAssertEqual(h.controller.state.localUsage?.totalTokens, 900)
    }

    func testTimeoutCancelsWorkAndLateSuccessCannotPublishOrDeliverAlerts() async throws {
        let h = Harness()
        var alerts = 0
        h.controller.alertsEnabled = true
        h.controller.onQuotaAlert = { _, _ in alerts += 1 }
        h.controller.refreshOfficial()
        XCTAssertTrue(h.executor.run(.official))
        let cancellation = try XCTUnwrap(h.stub.officialCancellation)
        h.stub.change { $0.now.addTimeInterval(46) }
        h.controller.heartbeat()
        XCTAssertThrowsError(try cancellation.check())
        XCTAssertEqual(h.controller.freshness.quota.status, .failed)
        await h.flushCompletions()
        XCTAssertNil(h.controller.state.weeklyWindow)
        XCTAssertEqual(alerts, 0)
        XCTAssertEqual(h.executor.count(.official), 0)
        h.controller.refreshOfficial() // Explicit refresh bypasses timeout backoff.
        try await h.complete(.official)
        XCTAssertEqual(h.controller.state.weeklyRemaining, 75)
        XCTAssertEqual(alerts, 1)
    }

    func testWakeKeepsOneWorkerPerLaneAndDiscardsPreSleepResults() async throws {
        let h = Harness()
        h.controller.refresh()
        XCTAssertTrue(h.executor.run(.official))
        h.controller.sleep()
        for _ in 0..<10 { h.controller.heartbeat() }
        h.controller.wake()
        XCTAssertEqual(h.executor.count(.official), 0)
        XCTAssertEqual(h.executor.count(.local), 1)
        await h.flushCompletions()
        XCTAssertNil(h.controller.state.weeklyWindow)
        XCTAssertEqual(h.executor.count(.official), 1)
        try await h.complete(.local) // Cancelled pre-sleep worker releases its lane.
        XCTAssertNil(h.controller.state.localUsage)
        try await h.complete(.official)
        // Official context invalidates the context-free wake scan, then starts one replacement.
        try await h.complete(.local)
        try await h.complete(.local)
        XCTAssertEqual(h.controller.state.weeklyRemaining, 75)
        XCTAssertEqual(h.controller.state.localUsage?.totalTokens, 100)
        XCTAssertEqual(h.executor.count(.official), 0)
        XCTAssertEqual(h.executor.count(.local), 0)
    }

    func testOfflineAllowsLocalReadsAndNetworkRecoveryStartsOfficialRequest() async throws {
        let h = Harness()
        h.controller.setNetworkAvailable(false)
        h.controller.refresh()
        XCTAssertEqual(h.executor.count(.official), 0)
        try await h.complete(.local)
        XCTAssertEqual(h.controller.state.localUsage?.totalTokens, 100)
        XCTAssertEqual(h.controller.freshness.networkAvailable, false)
        h.controller.setNetworkAvailable(true)
        XCTAssertEqual(h.executor.count(.official), 1)
        try await h.complete(.official)
        XCTAssertEqual(h.controller.freshness.quota.status, .success)
    }

    func testRepeatedRebuildRequestsCoalesceAndPropagateCurrentQuotaSample() async throws {
        let h = Harness()
        h.controller.refreshOfficial()
        try await h.complete(.official)
        for _ in 0..<20 {
            h.controller.refreshLocal(reason: .rebuild)
            h.controller.heartbeat()
        }
        XCTAssertEqual(h.executor.count(.local), 1)
        try await h.complete(.local)
        XCTAssertEqual(h.executor.count(.local), 1)
        try await h.complete(.local)
        XCTAssertEqual(h.executor.count(.local), 0)
        XCTAssertEqual(h.stub.requests.map(\.rebuild), [false, true])
        let request = try XCTUnwrap(h.stub.requests.last)
        XCTAssertEqual(request.accountContext, h.controller.state.accountContext)
        XCTAssertEqual(request.quotaSampleAt, h.controller.state.quotaSampleAt)
        XCTAssertEqual(request.weeklyWindow?.remainingPercent, 75)
    }

    func testPartialLocalResultReplacesValueButFailedReadRetainsIt() async throws {
        let h = Harness()
        h.stub.change { $0.localError = "One file unreadable" }
        h.controller.refreshLocal()
        try await h.complete(.local)
        XCTAssertEqual(h.controller.freshness.localUsage.status, .partial)
        XCTAssertEqual(h.controller.state.localUsage?.totalTokens, 100)
        h.stub.change { $0.localThrows = true; $0.tokens = 900 }
        h.controller.refreshLocal()
        try await h.complete(.local)
        XCTAssertEqual(h.controller.freshness.localUsage.status, .failed)
        XCTAssertEqual(h.controller.state.localUsage?.totalTokens, 100)
        h.stub.change { $0.localThrows = false; $0.localError = nil }
        h.controller.refreshLocal()
        try await h.complete(.local)
        XCTAssertEqual(h.controller.state.localUsage?.totalTokens, 900)
        XCTAssertEqual(h.controller.freshness.localUsage.status, .success)
    }

    func testStopCancelsAndNeverSchedulesFollowUpsOrPublishesQueuedResults() async throws {
        let h = Harness()
        h.controller.refresh()
        XCTAssertTrue(h.executor.run(.official))
        h.controller.stop()
        await h.flushCompletions()
        try await h.complete(.local)
        h.controller.wake()
        h.controller.refresh()
        h.controller.heartbeat()
        h.controller.setNetworkAvailable(false)
        h.controller.setNetworkAvailable(true)
        XCTAssertNil(h.controller.state.weeklyWindow)
        XCTAssertNil(h.controller.state.localUsage)
        XCTAssertEqual(h.executor.count(.official), 0)
        XCTAssertEqual(h.executor.count(.local), 0)
    }
}

@MainActor
private final class Harness {
    let stub = StubServices()
    let executor = ManualRefreshExecutor()
    let controller: UsageRefreshController
    let alerts = AlertSink()
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var historyURL: URL { directory.appendingPathComponent("history.json") }

    init(monitor: QuotaMonitor? = nil, realHistory: Bool = false) {
        let stub = stub
        let monitor = monitor ?? (realHistory ? QuotaMonitor(fileURL: directory.appendingPathComponent("history.json")) : nil)
        controller = UsageRefreshController(services: UsageRefreshServices(
            identity: { stub.settings.account }, official: { try stub.official($0) },
            local: { try stub.local($0, cancellation: $1) }, history: {
                monitor?.update(window: $0, at: stub.settings.now, alertsEnabled: $1, accountContext: $2)
                    ?? stub.history($0, enabled: $1, context: $2)
            }, acknowledgeAlert: {
                stub.recordAcknowledgement($0)
                return monitor?.acknowledge($0)
            }),
            executor: executor, now: { stub.settings.now })
        let alerts = alerts
        controller.onQuotaAlert = { alerts.receive($0, completion: $1) }
        controller.onCancelQuotaAlerts = { alerts.cancelled.append(contentsOf: $0) }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func complete(_ lane: RefreshLane, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertTrue(executor.run(lane), "No queued \(lane) work", file: file, line: line)
        await flushCompletions()
    }

    func flushCompletions() async {
        // Workers enqueue completion on this serial queue. This barrier follows them,
        // without sleeps, polling or reliance on the speed of the test machine.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

@MainActor
private final class AlertSink {
    var requests: [QuotaAlertRequest] = []
    var cancelled: [String] = []
    private var completions: [@MainActor @Sendable (String?) -> Void] = []

    func receive(_ request: QuotaAlertRequest, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        requests.append(request)
        completions.append(completion)
    }

    func finish(_ index: Int, error: String? = nil) { completions[index](error) }
}

private final class ManualRefreshExecutor: RefreshExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [RefreshLane: [@Sendable () -> Void]] = [:]

    func execute(_ lane: RefreshLane, work: @escaping @Sendable () -> Void) {
        lock.withLock { jobs[lane, default: []].append(work) }
    }
    func count(_ lane: RefreshLane) -> Int { lock.withLock { jobs[lane, default: []].count } }
    @discardableResult func run(_ lane: RefreshLane) -> Bool {
        let job: (@Sendable () -> Void)? = lock.withLock {
            guard !jobs[lane, default: []].isEmpty else { return nil }
            return jobs[lane]!.removeFirst()
        }
        guard let job else { return false }
        job()
        return true
    }
}

private final class StubServices: @unchecked Sendable {
    struct Settings {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var account = "a"
        var serverAccount: String?
        var balance: String? = "12.5"
        var hasQuota = true
        var remaining = 75
        var resetAt = 1_800_400_000
        var officialError: String?
        var resetError: String?
        var localError: String?
        var localThrows = false
        var tokens: Int64 = 100
    }
    private let lock = NSLock()
    private var stored = Settings()
    private var storedRequests: [LocalUsageRequest] = []
    private var storedOfficialCancellation: RefreshCancellation?
    private var storedAcknowledgements: [QuotaAlertEvent] = []
    var settings: Settings { lock.withLock { stored } }
    var requests: [LocalUsageRequest] { lock.withLock { storedRequests } }
    var officialCancellation: RefreshCancellation? { lock.withLock { storedOfficialCancellation } }
    var acknowledgements: [QuotaAlertEvent] { lock.withLock { storedAcknowledgements } }
    func recordAcknowledgement(_ event: QuotaAlertEvent) { lock.withLock { storedAcknowledgements.append(event) } }
    func change(_ update: (inout Settings) -> Void) { lock.withLock { update(&stored) } }

    func official(_ cancellation: RefreshCancellation) throws -> OfficialUsageUpdate {
        lock.withLock { storedOfficialCancellation = cancellation }
        let s = settings
        if let error = s.officialError { throw RuntimeError(error) }
        let context = CodexAccountContext(codexHome: "/fixture", authenticationSource: "/fixture/auth.json",
            accountKey: s.serverAccount ?? s.account, accountLabel: nil, limitID: "codex")
        let reset = ResetCreditsSnapshot(fetchedAtIso: iso(s.now), availableCount: s.resetError == nil ? 3 : nil,
                                         credits: [], error: s.resetError, display: nil)
        let quota = s.hasQuota ? RateLimitWindow(usedPercent: 100 - s.remaining, remainingPercent: s.remaining, windowDurationMins: 10080,
                                               resetsAt: s.resetAt, resetsAtIso: nil) : nil
        let rate = RateLimitSnapshot(limitId: "codex", limitName: nil, planType: nil, rateLimitReachedType: nil,
            primary: quota, secondary: nil, credits: s.balance.map { CreditsSnapshot(hasCredits: true, unlimited: false, balance: $0) }, individualLimit: nil)
        return OfficialUsageUpdate(RateLimitPayload(fetchedAtIso: iso(s.now), rateLimits: rate, rateLimitsByLimitId: nil,
            display: nil, resetCredits: reset, localUsage: nil, rateLimitError: nil, localUsageError: nil, usage: nil, accountContext: context))
    }

    func local(_ request: LocalUsageRequest, cancellation: RefreshCancellation) throws -> LocalUsageSnapshot {
        lock.withLock { storedRequests.append(request) }
        let s = settings
        if s.localThrows { throw RuntimeError("Local read failed") }
        return LocalUsageSnapshot(fetchedAtIso: iso(s.now), source: "/fixture", timezone: "UTC", localDate: "2027-01-15",
            inputTokens: s.tokens, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0,
            totalTokens: s.tokens, cacheHitPercent: 0, eventCount: 1, duplicateEventCount: 0, importedEventCount: 0,
            regressionEventCount: 0, filesScanned: 1, filesWithEvents: 1, parseErrorCount: 0, error: s.localError,
            topFiles: [], todayCost: nil, weeklyQuotaCost: nil, display: nil, accountContext: request.accountContext)
    }

    func history(_ window: RateLimitWindow, enabled: Bool, context: CodexAccountContext?) -> QuotaMonitorSnapshot {
        let event = QuotaAlertEvent(kind: .warning, windowID: QuotaWindowID(window: window)!, remainingPercent: 75,
            resetAt: window.resetDate!, projectedExhaustionAt: nil, accountScopeKey: context?.scopeKey)
        return QuotaMonitorSnapshot(forecast: nil, alerts: enabled ? [event] : [], sampleCount: 1, persistenceError: nil)
    }
    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
