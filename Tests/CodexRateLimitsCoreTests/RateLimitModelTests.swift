import Foundation
import XCTest
@testable import CodexRateLimitsCore

final class RateLimitModelTests: XCTestCase {
    func testWeeklyWindowCanComeFromEitherLane() {
        let session = window(durationMinutes: 300, remaining: 80)
        let weekly = window(durationMinutes: 10_080, remaining: 42)

        let primaryWeekly = snapshot(primary: weekly, secondary: session)
        XCTAssertEqual(primaryWeekly.weeklyWindow?.remainingPercent, 42)

        let secondaryWeekly = snapshot(primary: session, secondary: weekly)
        XCTAssertEqual(secondaryWeekly.weeklyWindow?.remainingPercent, 42)

        let noWeekly = snapshot(primary: session, secondary: nil)
        XCTAssertNil(noWeekly.weeklyWindow)
    }

    func testResetDateSupportsEpochAndISO8601() throws {
        let epoch = RateLimitWindow(
            usedPercent: 10,
            remainingPercent: 90,
            windowDurationMins: 10_080,
            resetsAt: 1_787_000_000,
            resetsAtIso: nil
        )
        XCTAssertEqual(epoch.resetDate?.timeIntervalSince1970, 1_787_000_000)

        let iso = RateLimitWindow(
            usedPercent: 10,
            remainingPercent: 90,
            windowDurationMins: 10_080,
            resetsAt: nil,
            resetsAtIso: "2026-07-14T08:09:10.123Z"
        )
        let resetDate = try XCTUnwrap(iso.resetDate)
        XCTAssertEqual(resetDate.timeIntervalSince1970, 1_784_016_550.123, accuracy: 0.001)
    }

    private func window(durationMinutes: Int, remaining: Int) -> RateLimitWindow {
        RateLimitWindow(
            usedPercent: 100 - remaining,
            remainingPercent: remaining,
            windowDurationMins: durationMinutes,
            resetsAt: nil,
            resetsAtIso: nil
        )
    }

    private func snapshot(primary: RateLimitWindow?, secondary: RateLimitWindow?) -> RateLimitSnapshot {
        RateLimitSnapshot(
            limitId: nil,
            limitName: nil,
            planType: nil,
            rateLimitReachedType: nil,
            primary: primary,
            secondary: secondary,
            credits: nil,
            individualLimit: nil
        )
    }
}
