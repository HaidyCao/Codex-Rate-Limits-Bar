import Foundation
import XCTest
@testable import CodexRateLimitsCore

final class InputValidationTests: XCTestCase {
    func testMissingOrInconsistentTokenBreakdownRemainsUnpriced() throws {
        for fields in [
            ["total_tokens": 1000],
            ["total_tokens": 1000, "input_tokens": 100],
            ["total_tokens": 1000, "input_tokens": 1000, "cached_input_tokens": 1001],
            ["total_tokens": 1000, "input_tokens": 1000, "cached_input_tokens": 600, "cache_write_input_tokens": 500],
            ["total_tokens": 1000, "cached_input_tokens": Int.max, "cache_write_input_tokens": Int.max],
            ["total_tokens": 1000, "output_tokens": 1000, "reasoning_output_tokens": 1001]
        ] {
            let usage = try XCTUnwrap(TokenUsage.from(fields))
            var costs = TokenCostAccumulator()
            costs.add(usage: usage, model: "gpt-5.6-sol", requestInputTokens: 100, serviceTier: "standard")
            XCTAssertNil(costs.estimate().estimatedCostUSD)
            XCTAssertNil(costs.creditEstimate().estimatedCredits)
            XCTAssertEqual(costs.estimate().unpricedTokens, 1000)
            XCTAssertEqual(costs.creditEstimate().coveragePercent, 0)
            XCTAssertEqual(Set(costs.unpricedUsage().map(\.reason)), ["incompleteTokenBreakdown"])
            var weekly = WeeklyCostBucket()
            weekly.add(usage: usage, model: "gpt-5.6-sol", requestInput: 100, tier: "standard")
            XCTAssertEqual(weekly.unpricedTokens, 1000)
        }
    }

    func testOmittedZeroComponentsAndConfirmedZeroRemainPriceable() throws {
        for fields in [["total_tokens": 0], ["input_tokens": 1000, "total_tokens": 1000],
                       ["output_tokens": 1000, "total_tokens": 1000]] {
            let usage = try XCTUnwrap(TokenUsage.from(fields))
            XCTAssertNotNil(TokenCostEstimator.estimateUSD(usage: usage, model: "gpt-5.6-sol"))
        }
    }

    func testIncompleteCumulativeSamplesCannotProduceApparentlyPricedDelta() throws {
        let previous = try XCTUnwrap(TokenUsage.from(["total_tokens": 1000]))
        let current = try XCTUnwrap(TokenUsage.from(["total_tokens": 1500, "input_tokens": 500]))
        let delta = try XCTUnwrap(LocalUsageLog.positiveDelta(previous, current, sameSession: true))
        XCTAssertEqual(delta.totalTokens, 500)
        let restored = try JSONDecoder().decode(TokenUsage.self, from: JSONEncoder().encode(delta))
        XCTAssertNil(TokenCostEstimator.estimateUSD(usage: restored, model: "gpt-5.6-sol"))
    }

    func testMissingAndInvalidPercentAreUnavailableWhileZeroIsFull() {
        for value: Any in [NSNull(), true, -1, 101, 12.5, "unknown"] {
            let payload = quota(["usedPercent": value, "windowDurationMins": 10080])
            XCTAssertNil(payload.selectedRateLimit?.weeklyWindow)
            XCTAssertEqual(payload.display?.primaryLabel, "W --")
            XCTAssertEqual(RefreshOutcome.official(payload)[.quota]?.phase, .unavailable)
        }
        XCTAssertNil(quota(["windowDurationMins": 10080]).selectedRateLimit?.weeklyWindow)
        let zero = quota(["usedPercent": 0, "windowDurationMins": 10080])
        XCTAssertEqual(zero.selectedRateLimit?.weeklyWindow?.remainingPercent, 100)
        XCTAssertEqual(RefreshOutcome.official(zero)[.quota]?.phase, .success)
    }

    func testInvalidResetCountDoesNotBecomeZero() {
        for value: Any in [-1, true, 1.5, "invalid"] {
            let result = OfficialResponseNormalizer.normalizeResetCreditsResponse(["availableCount": value, "credits": []])
            XCTAssertNil(result.availableCount)
        }
        XCTAssertEqual(OfficialResponseNormalizer.normalizeResetCreditsResponse(["credits": []]).availableCount, 0)
    }

    func testIntegerConversionRejectsOverflowNonFiniteFractionsAndBooleans() throws {
        let json = try JSONSerialization.jsonObject(with: Data("[1e100,-1e100,1.5,true,9223372036854775808]".utf8)) as! [Any]
        for value in json + [Double.infinity, Double.nan, NSNull()] { XCTAssertNil(intValue(value)) }
        XCTAssertEqual(intValue(Int.max), Int.max)
        XCTAssertEqual(intValue(String(Int.min)), Int.min)
        XCTAssertEqual(intValue(42.0), 42)
        XCTAssertEqual(intValue("10080"), 10080)
        for value in json {
            XCTAssertNil(quota(["usedPercent": value, "windowDurationMins": 10080]).selectedRateLimit?.weeklyWindow)
        }
    }

    func testMalformedDatesAreDroppedWithoutLosingAValidPercentage() {
        for value: Any in [1e100, -1, true, Int.max, "NaN"] {
            let payload = quota(["usedPercent": 30, "windowDurationMins": 10080, "resetsAt": value])
            XCTAssertEqual(payload.selectedRateLimit?.weeklyWindow?.remainingPercent, 70)
            XCTAssertNil(payload.selectedRateLimit?.weeklyWindow?.resetDate)
            let reset = OfficialResponseNormalizer.normalizeResetCreditsResponse(["credits": [["status": "available", "expiresAt": value]]])
            XCTAssertNil(reset.credits.first?.expiresAtIso)
        }
        for value: Any in [0, -1, true, 1.5, 1e100, Int.max] {
            let payload = quota(["usedPercent": 30, "windowDurationMins": value])
            XCTAssertNil(payload.selectedRateLimit?.primary?.windowDurationMins)
            XCTAssertNil(payload.selectedRateLimit?.weeklyWindow)
        }
        for value in [1_800_000_000, 1_800_000_000_000] {
            let reset = OfficialResponseNormalizer.normalizeResetCreditsResponse(["credits": [["expiresAt": value]]])
            XCTAssertEqual(parseIsoDate(reset.credits.first?.expiresAtIso)?.timeIntervalSince1970, 1_800_000_000)
        }
    }

    func testInvalidBalancesAndUnlimitedFlagsDoNotReportSuccess() {
        for value: Any in [true, -1, "NaN", "Infinity", Double.infinity] {
            let payload = OfficialResponseNormalizer.normalizeRateLimitResponse(["rateLimits": [
                "credits": ["balance": value, "unlimited": 2]]])
            XCTAssertNil(payload.selectedRateLimit?.credits?.balance)
            XCTAssertEqual(RefreshOutcome.official(payload)[.credits]?.phase, .unavailable)
        }
        let zero = OfficialResponseNormalizer.normalizeRateLimitResponse(["rateLimits": ["credits": ["balance": "0"]]])
        XCTAssertEqual(RefreshOutcome.official(zero)[.credits]?.phase, .success)
        let unlimited = OfficialResponseNormalizer.normalizeRateLimitResponse(["rateLimits": ["credits": ["unlimited": true]]])
        XCTAssertEqual(RefreshOutcome.official(unlimited)[.credits]?.phase, .success)
    }

    private func quota(_ window: [String: Any]) -> RateLimitPayload {
        OfficialResponseNormalizer.normalizeRateLimitResponse(["rateLimits": ["limitId": "codex", "primary": window]])
    }
}
