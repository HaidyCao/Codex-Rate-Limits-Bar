import Foundation
import XCTest
@testable import CodexRateLimitsCore

final class RefreshStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func success(_ lane: RefreshLane, at date: Date) -> [RefreshSource: RefreshOutcome] {
        Dictionary(uniqueKeysWithValues: lane.sources.map { ($0, RefreshOutcome(.success, at: date)) })
    }
    private func failure(_ lane: RefreshLane) -> [RefreshSource: RefreshOutcome] {
        Dictionary(uniqueKeysWithValues: lane.sources.map { ($0, RefreshOutcome(.failed, error: "offline")) })
    }
    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    func testFailuresKeepTheirOwnDataTimesAndSurviveOtherRefreshes() throws {
        var state = RefreshCoordinator(accountIdentity: "a")
        let initial = try XCTUnwrap(state.request(.official, reason: .manual, now: now))
        XCTAssertTrue(state.complete(initial, outcomes: success(.official, at: now), now: now))
        let secondAt = now.addingTimeInterval(60)
        let second = try XCTUnwrap(state.request(.official, reason: .timer, now: secondAt))
        var mixed = success(.official, at: secondAt)
        mixed[.resetCredits] = RefreshOutcome(.failed, error: "reset unavailable")
        state.complete(second, outcomes: mixed, now: secondAt)
        let local = try XCTUnwrap(state.request(.local, reason: .manual, now: secondAt))
        state.complete(local, outcomes: success(.local, at: secondAt), now: secondAt)
        let snapshot = state.snapshot(now: secondAt)
        XCTAssertEqual(snapshot.quota.lastSuccessAtIso, iso(secondAt))
        XCTAssertEqual(snapshot.resetCredits.lastSuccessAtIso, iso(now))
        XCTAssertEqual(snapshot.resetCredits.dataAtIso, iso(now))
        XCTAssertEqual(snapshot.resetCredits.error, "reset unavailable")
        _ = state.request(.official, reason: .manual, now: secondAt)
        XCTAssertEqual(state.snapshot(now: secondAt).resetCredits.error, "reset unavailable")
        XCTAssertEqual(state.snapshot(now: secondAt).resetCredits.status, .refreshing)
    }

    func testFailedResetFieldDoesNotBackOffHealthyQuotaAndBalance() throws {
        var state = RefreshCoordinator(accountIdentity: "a")
        var date = now
        for _ in 0..<8 {
            let ticket = try XCTUnwrap(state.request(.official, reason: .timer, now: date))
            var outcomes = success(.official, at: date)
            outcomes[.resetCredits] = RefreshOutcome(.failed, error: "reset endpoint unavailable")
            state.complete(ticket, outcomes: outcomes, now: date)
            let snapshot = state.snapshot(now: date)
            XCTAssertEqual(snapshot.quota.lastSuccessAtIso, iso(date))
            XCTAssertNil(snapshot.quota.nextRetryAtIso)
            XCTAssertEqual(snapshot.resetCredits.nextRetryAtIso, iso(date.addingTimeInterval(60)))
            date.addTimeInterval(60)
        }
        XCTAssertFalse(state.snapshot(now: date).quota.isStale)
        XCTAssertNotNil(state.snapshot(now: date).resetCredits.error)
    }

    func testStalenessAdvancesWithoutAnotherRequestAndSurvivesFailure() throws {
        var state = RefreshCoordinator(accountIdentity: "a")
        for lane in RefreshLane.allCases {
            let ticket = try XCTUnwrap(state.request(lane, reason: .manual, now: now))
            state.complete(ticket, outcomes: success(lane, at: now), now: now)
        }
        XCTAssertFalse(state.snapshot(now: now.addingTimeInterval(120)).localUsage.isStale)
        XCTAssertEqual(state.snapshot(now: now.addingTimeInterval(121)).localUsage.status, .stale)
        XCTAssertEqual(state.snapshot(now: now.addingTimeInterval(301)).quota.status, .stale)
        let later = now.addingTimeInterval(301)
        let ticket = try XCTUnwrap(state.request(.official, reason: .manual, now: later))
        XCTAssertTrue(state.snapshot(now: later).quota.isStale)
        state.complete(ticket, outcomes: failure(.official), now: later)
        let old = state.snapshot(now: later).quota
        XCTAssertEqual(old.status, .failed)
        XCTAssertTrue(old.isStale)
        XCTAssertEqual(old.ageSeconds, 301)
        XCTAssertEqual(old.lastSuccessAtIso, iso(now))
    }

    func testPartialScanDoesNotClaimCompleteSuccessAndUnavailableClearsValueTime() throws {
        var state = RefreshCoordinator(accountIdentity: "a")
        let first = try XCTUnwrap(state.request(.local, reason: .manual, now: now))
        state.complete(first, outcomes: success(.local, at: now), now: now)
        let later = now.addingTimeInterval(30)
        let second = try XCTUnwrap(state.request(.local, reason: .timer, now: later))
        state.complete(second, outcomes: [.localUsage: RefreshOutcome(.partial, at: later, error: "Unreadable log")], now: later)
        let partial = state.snapshot(now: later).localUsage
        XCTAssertEqual(partial.status, .partial)
        XCTAssertEqual(partial.dataAtIso, iso(later))
        XCTAssertEqual(partial.lastSuccessAtIso, iso(now))
        let third = try XCTUnwrap(state.request(.local, reason: .manual, now: later))
        state.complete(third, outcomes: [.localUsage: RefreshOutcome(.unavailable)], now: later)
        XCTAssertNil(state.snapshot(now: later).localUsage.dataAtIso)
        XCTAssertEqual(state.snapshot(now: later).localUsage.lastSuccessAtIso, iso(now))
    }

    func testBackoffIsBoundedManualRefreshBypassesItAndSuccessResetsIt() throws {
        var state = RefreshCoordinator(accountIdentity: "a")
        var date = now
        for delay in [60.0, 120, 240, 480, 600, 600] {
            let ticket = try XCTUnwrap(state.request(.official, reason: .timer, now: date))
            state.complete(ticket, outcomes: failure(.official), now: date)
            XCTAssertEqual(state.snapshot(now: date).quota.nextRetryAtIso, iso(date.addingTimeInterval(delay)))
            XCTAssertNil(state.request(.official, reason: .quotaChanged, now: date.addingTimeInterval(delay - 1)))
            date.addTimeInterval(delay)
        }
        let manual = try XCTUnwrap(state.request(.official, reason: .manual, now: date.addingTimeInterval(-599)))
        state.complete(manual, outcomes: success(.official, at: manual.startedAt), now: manual.startedAt)
        XCTAssertNil(state.snapshot(now: manual.startedAt).quota.nextRetryAtIso)
        // A new successful lane follows its regular interval.
        XCTAssertNil(state.request(.official, reason: .timer, now: manual.startedAt.addingTimeInterval(59)))
        XCTAssertNotNil(state.request(.official, reason: .timer, now: manual.startedAt.addingTimeInterval(60)))
    }

    func testBusyRequestsCoalesceAndPreserveExplicitRebuild() throws {
        var state = RefreshCoordinator(accountIdentity: "a")
        let first = try XCTUnwrap(state.request(.local, reason: .manual, now: now))
        for _ in 0..<100 {
            XCTAssertNil(state.request(.local, reason: .timer, now: now))
            XCTAssertNil(state.request(.local, reason: .manual, now: now))
        }
        XCTAssertNil(state.request(.local, reason: .rebuild, now: now))
        state.complete(first, outcomes: success(.local, at: now), now: now)
        let second = try XCTUnwrap(state.request(.local, reason: .timer, now: now))
        XCTAssertTrue(second.rebuild)
        state.complete(second, outcomes: success(.local, at: now), now: now)
        XCTAssertNil(state.request(.local, reason: .timer, now: now))
    }

    func testTimerTicksWhileBusyDoNotQueueExtraWork() throws {
        var state = RefreshCoordinator(accountIdentity: "a")
        let ticket = try XCTUnwrap(state.request(.official, reason: .timer, now: now))
        for _ in 0..<20 { XCTAssertNil(state.request(.official, reason: .timer, now: now)) }
        state.complete(ticket, outcomes: success(.official, at: now), now: now)
        XCTAssertNil(state.request(.official, reason: .timer, now: now))
    }

    func testOfflineDoesNotBlockLocalUsageAndRecoveryBypassesBackoff() throws {
        var state = RefreshCoordinator(accountIdentity: "a")
        let ticket = try XCTUnwrap(state.request(.official, reason: .manual, now: now))
        state.complete(ticket, outcomes: failure(.official), now: now)
        XCTAssertFalse(state.setNetworkAvailable(false))
        XCTAssertNil(state.request(.official, reason: .manual, now: now))
        XCTAssertNotNil(state.request(.local, reason: .manual, now: now))
        XCTAssertTrue(state.setNetworkAvailable(true))
        XCTAssertFalse(state.setNetworkAvailable(true))
        XCTAssertNotNil(state.request(.official, reason: .recovery, now: now))
    }

    func testServerReportedContextChangeClearsPriorAccountSuccessTimes() throws {
        var state = RefreshCoordinator(accountIdentity: "managed-store")
        let old = try XCTUnwrap(state.request(.official, reason: .manual, now: now))
        state.complete(old, outcomes: success(.official, at: now), now: now)
        let later = now.addingTimeInterval(60)
        let new = try XCTUnwrap(state.request(.official, reason: .timer, now: later))
        var outcomes = success(.official, at: later)
        outcomes[.resetCredits] = RefreshOutcome(.failed, error: "new account has no reset result")
        state.complete(new, outcomes: outcomes, now: later, resetHistory: true)
        XCTAssertEqual(state.snapshot(now: later).quota.lastSuccessAtIso, iso(later))
        XCTAssertNil(state.snapshot(now: later).resetCredits.lastSuccessAtIso)
        XCTAssertNil(state.snapshot(now: later).resetCredits.dataAtIso)
        XCTAssertEqual(state.snapshot(now: later).resetCredits.lastAttemptAtIso, iso(later))
    }

    func testAccountSwitchDiscardsLateDataAndAnOldCompletionCannotReleaseNewWorker() throws {
        var state = RefreshCoordinator(accountIdentity: "a")
        let old = try XCTUnwrap(state.request(.official, reason: .manual, now: now))
        XCTAssertEqual(state.changeAccount(to: "b", now: now), [old])
        XCTAssertNil(state.snapshot(now: now).quota.lastSuccessAtIso)
        XCTAssertFalse(state.accepts(old))
        XCTAssertNil(state.request(.official, reason: .manual, now: now))
        XCTAssertFalse(state.complete(old, outcomes: success(.official, at: now), now: now))
        let current = try XCTUnwrap(state.request(.official, reason: .timer, now: now))
        XCTAssertEqual(current.accountIdentity, "b")
        XCTAssertFalse(state.complete(old, outcomes: failure(.official), now: now))
        XCTAssertTrue(state.accepts(current))
        XCTAssertEqual(state.snapshot(now: now).quota.status, .refreshing)
        XCTAssertNil(state.snapshot(now: now).quota.error)
    }

    func testTimeoutLeavesFailedStateAndBoundsPhysicalWorkersUntilCancellationCompletes() throws {
        var state = RefreshCoordinator(accountIdentity: "a")
        let old = try XCTUnwrap(state.request(.official, reason: .manual, now: now))
        let late = old.deadline.addingTimeInterval(1)
        XCTAssertEqual(state.expire(now: late), [old])
        XCTAssertTrue(state.expire(now: late).isEmpty)
        XCTAssertEqual(state.snapshot(now: late).quota.status, .failed)
        for _ in 0..<100 { XCTAssertNil(state.request(.official, reason: .manual, now: late)) }
        XCTAssertFalse(state.complete(old, outcomes: success(.official, at: late), now: late))
        XCTAssertNil(state.snapshot(now: late).quota.lastSuccessAtIso)
        let new = try XCTUnwrap(state.request(.official, reason: .timer, now: late))
        XCTAssertTrue(state.complete(new, outcomes: success(.official, at: late), now: late))
    }

    func testCompletionPastDeadlineFailsEvenBeforeHeartbeatAndCanRetry() throws {
        var state = RefreshCoordinator(accountIdentity: "a")
        let old = try XCTUnwrap(state.request(.local, reason: .manual, now: now))
        let late = old.deadline.addingTimeInterval(1)
        XCTAssertFalse(state.complete(old, outcomes: success(.local, at: late), now: late))
        XCTAssertEqual(state.snapshot(now: late).localUsage.status, .failed)
        XCTAssertNil(state.request(.local, reason: .timer, now: late))
        XCTAssertNotNil(state.request(.local, reason: .timer, now: late.addingTimeInterval(30)))
    }

    func testWakeAndScopeInvalidationDiscardOldLocalResultsWithoutErasingOfficialData() throws {
        var state = RefreshCoordinator(accountIdentity: "a")
        let official = try XCTUnwrap(state.request(.official, reason: .manual, now: now))
        state.complete(official, outcomes: success(.official, at: now), now: now)
        let old = try XCTUnwrap(state.request(.local, reason: .manual, now: now))
        XCTAssertEqual(state.invalidate(.local, now: now, clear: true), old)
        XCTAssertFalse(state.complete(old, outcomes: success(.local, at: now), now: now))
        XCTAssertEqual(state.snapshot(now: now).quota.status, .success)
        XCTAssertNil(state.snapshot(now: now).localUsage.dataAtIso)
        let resumed = try XCTUnwrap(state.request(.local, reason: .recovery, now: now))
        XCTAssertNotEqual(resumed.generation, old.generation)
        state.complete(resumed, outcomes: success(.local, at: now), now: now)
        state.invalidate(.official, now: now)
        XCTAssertEqual(state.snapshot(now: now).quota.lastSuccessAtIso, iso(now))
        XCTAssertNotNil(state.request(.official, reason: .recovery, now: now))
    }

    func testCancellationAndDeadlineInterruptWaits() throws {
        let token = RefreshCancellation(deadline: Date().addingTimeInterval(5))
        try token.check()
        token.cancel()
        XCTAssertThrowsError(try RefreshWork.$cancellation.withValue(token) {
            try RefreshWork.wait(DispatchSemaphore(value: 0), timeout: 10)
        })
        let expired = RefreshCancellation(deadline: Date().addingTimeInterval(-1))
        XCTAssertThrowsError(try expired.check())
        let soon = RefreshCancellation(deadline: Date().addingTimeInterval(0.06))
        let start = Date()
        XCTAssertThrowsError(try RefreshWork.$cancellation.withValue(soon) {
            try RefreshWork.wait(DispatchSemaphore(value: 0), timeout: 10)
        })
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testOfficialFieldsDistinguishMissingBalanceFromZeroAndCountOnlyReset() throws {
        var response: [String: Any] = ["rateLimits": ["limitId": "codex", "secondary": ["usedPercent": 30, "windowDurationMins": 10080],
            "credits": ["hasCredits": false, "unlimited": false, "balance": "0"]]]
        let fixtureHome = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-fixture-no-login-\(UUID())")
        func outcomes() throws -> [RefreshSource: RefreshOutcome] {
            let payload = try OfficialUsageClient(
                sourceProvider: { CodexAccountSource(environment: ["CODEX_HOME": fixtureHome.path]) },
                call: { _, _ in ["account/read": [:], "account/rateLimits/read": response] },
                fetchReset: { _ in XCTFail("Fixture must not make a network request"); return Data() }).readAccountPayload(includeUsage: false)
            return RefreshOutcome.official(payload)
        }
        response["rateLimitResetCredits"] = ["availableCount": 3, "credits": NSNull()]
        XCTAssertEqual(try outcomes()[.quota]?.phase, .success)
        XCTAssertEqual(try outcomes()[.credits]?.phase, .success)
        XCTAssertEqual(try outcomes()[.resetCredits]?.phase, .partial)
        XCTAssertNil(try outcomes()[.resetCredits]?.error)
        response["rateLimits"] = ["limitId": "codex", "credits": ["hasCredits": false, "unlimited": false, "balance": "NaN"]]
        response["rateLimitResetCredits"] = [:]
        XCTAssertEqual(try outcomes()[.quota]?.phase, .unavailable)
        XCTAssertEqual(try outcomes()[.credits]?.phase, .unavailable)
        XCTAssertEqual(try outcomes()[.resetCredits]?.phase, .unavailable)
    }

    func testCountOnlyResetUsesRegularCadenceAndRetainsSuccessTime() throws {
        var state = RefreshCoordinator(accountIdentity: "a")
        let ticket = try XCTUnwrap(state.request(.official, reason: .manual, now: now))
        var outcomes = success(.official, at: now)
        outcomes[.resetCredits] = RefreshOutcome(.partial, at: now)
        state.complete(ticket, outcomes: outcomes, now: now)
        XCTAssertEqual(state.snapshot(now: now).resetCredits.lastSuccessAtIso, iso(now))
        XCTAssertNil(state.snapshot(now: now).resetCredits.nextRetryAtIso)
    }
}
