import XCTest
@testable import CodexRateLimitsCore

final class CreditAccountingTests: XCTestCase {
    func testOriginalV1CustomCardRetainsExplicitWriteRatesAndLongContext() throws {
        let data = Data(#"{"schemaVersion":1,"api":{"version":"legacy","verifiedAt":"2026-09-01","sources":["https://example.com"],"conditions":["fixture"],"models":{},"aliases":{}},"credits":{"version":"legacy","verifiedAt":"2026-09-01","sources":["https://example.com"],"conditions":["fixture"],"models":{"private-model":{"input":50,"cachedInput":5,"cacheWriteInput":0,"output":250,"datedSnapshots":false,"contextTier":{"threshold":272000,"inputMultiplier":2,"outputMultiplier":1.5},"serviceTiers":{"standard":1}}},"aliases":{}}}"#.utf8)
        var document = try PricingCatalog.decode(data)
        let writes = TokenUsage(inputTokens: 100_000, cacheWriteInputTokens: 100_000, totalTokens: 100_000)
        let mixed = TokenUsage(inputTokens: 100_000, cachedInputTokens: 40_000, cacheWriteInputTokens: 20_000,
                               outputTokens: 5_000, totalTokens: 105_000)
        for (writeRate, expectedWrites, expectedMixed) in [(0.0, 0.0, 6.275), (80.0, 16.0, 9.475)] {
            document.credits.models["private-model"]?.cacheWriteInput = writeRate
            let snapshot = PricingCatalog.snapshot(document, source: "custom", path: nil, error: nil)
            try PricingCatalog.$current.withValue(snapshot) {
                for (usage, expected) in [(writes, expectedWrites), (mixed, expectedMixed)] {
                    XCTAssertEqual(try XCTUnwrap(CodexCreditEstimator.estimate(usage: usage, model: "private-model",
                        requestInputTokens: 300_000, serviceTier: "standard")), expected, accuracy: 1e-12)
                }
            }
        }
    }

    func testCreditPolicyIsValidatedAndParticipatesInRepricing() throws {
        let encoder = JSONEncoder()
        var document = PricingCatalog.builtin.document
        document.api.models["gpt-6.1-sol"]?.cacheWriteInputUnverified = false
        XCTAssertThrowsError(try PricingCatalog.decode(encoder.encode(document)))
        document = PricingCatalog.builtin.document
        document.credits.models["gpt-6.1-sol"]?.cacheWriteInputUnverified = nil
        let original = PricingCatalog.snapshot(try PricingCatalog.decode(encoder.encode(document)), source: "custom", path: nil, error: nil)
        var accumulator = TokenCostAccumulator()
        PricingCatalog.$current.withValue(original) {
            accumulator.add(usage: TokenUsage(inputTokens: 10, cacheWriteInputTokens: 10, totalTokens: 10),
                            model: "gpt-6.1-sol", requestInputTokens: 10, serviceTier: "standard")
            XCTAssertEqual(accumulator.creditEstimate().estimatedCredits, 0)
        }
        XCTAssertTrue(accumulator.requiresRepricing)
        XCTAssertEqual(accumulator.unpricedUsage().map(\.reason), ["stalePricing", "stalePricing"])
        let encoded = String(decoding: try encoder.encode(PricingCatalog.builtin.document), as: UTF8.self)
        XCTAssertThrowsError(try PricingCatalog.decode(Data(encoded.replacingOccurrences(
            of: "\"cacheWriteInputUnverified\":true", with: "\"cacheWriteInputUnverified\":\"yes\"").utf8)))
    }

    func testReportedCacheWritesStayUnpricedWithoutDiscardingTokensOrAPIAmounts() throws {
        for (usage, expectedAPI) in [
            (TokenUsage(inputTokens: 100_000, cacheWriteInputTokens: 100_000, totalTokens: 100_000), 0.25),
            (TokenUsage(inputTokens: 100_000, cachedInputTokens: 40_000, cacheWriteInputTokens: 20_000,
                        outputTokens: 5_000, totalTokens: 105_000), 0.184)
        ] {
            var accumulator = TokenCostAccumulator()
            accumulator.add(usage: usage, model: "gpt-6.1-sol", requestInputTokens: 100_000, serviceTier: "fast")
            XCTAssertEqual(try XCTUnwrap(accumulator.estimate().estimatedCostUSD), expectedAPI, accuracy: 1e-12)
            XCTAssertEqual(accumulator.estimate().coveragePercent, 100)
            XCTAssertNil(accumulator.creditEstimate().estimatedCredits)
            XCTAssertEqual(accumulator.creditEstimate().unpricedTokens, usage.totalTokens)
            XCTAssertEqual(accumulator.unpricedUsage().map(\.reason), ["unverifiedCacheWrite"])
            XCTAssertFalse(accumulator.requiresRepricing)
        }
    }

    func testOmittedWritesAndExplicitZeroRetainPublishedCreditEstimate() throws {
        var counters: [String: Any] = ["input_tokens": 100_000, "cached_input_tokens": 40_000,
                                       "output_tokens": 5_000, "total_tokens": 105_000]
        for writes in [nil, 0] as [Int?] {
            counters["cache_write_input_tokens"] = writes
            let usage = try XCTUnwrap(TokenUsage.from(counters))
            XCTAssertEqual(try XCTUnwrap(CodexCreditEstimator.estimate(usage: usage, model: "gpt-6.1-sol",
                requestInputTokens: 100_000, serviceTier: "standard")), 4.35, accuracy: 1e-12)
        }
    }

    func testContradictoryComponentsRemainIncompleteForBothEstimates() {
        let usage = TokenUsage(inputTokens: 100, cachedInputTokens: 80, cacheWriteInputTokens: 30, totalTokens: 100)
        var accumulator = TokenCostAccumulator()
        accumulator.add(usage: usage, model: "gpt-6.1-sol", requestInputTokens: 100, serviceTier: "standard")
        XCTAssertNil(accumulator.estimate().estimatedCostUSD)
        XCTAssertNil(accumulator.creditEstimate().estimatedCredits)
        XCTAssertEqual(accumulator.unpricedUsage().map(\.reason), ["incompleteTokenBreakdown", "incompleteTokenBreakdown"])
    }

    func testUnpublishedLongContextCreditsDoNotBorrowAPITiers() throws {
        let usage = TokenUsage(inputTokens: 100_000, totalTokens: 100_000)
        for model in ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna",
                      "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4"] {
            XCTAssertNotNil(CodexCreditEstimator.estimate(usage: usage, model: model,
                requestInputTokens: 272_000, serviceTier: "standard"), model)
            var accumulator = TokenCostAccumulator()
            accumulator.add(usage: usage, model: model, requestInputTokens: 272_001, serviceTier: "standard")
            XCTAssertNotNil(accumulator.estimate().estimatedCostUSD, model)
            XCTAssertNil(accumulator.creditEstimate().estimatedCredits, model)
            XCTAssertEqual(accumulator.unpricedUsage().map(\.reason), ["unsupportedContext"], model)
        }
    }

    func testMissingContextIsAnAssumptionAndKnownAmountsSurviveSerialization() throws {
        var accumulator = TokenCostAccumulator()
        let usage = TokenUsage(inputTokens: 100_000, totalTokens: 100_000)
        accumulator.add(usage: usage, model: "gpt-6.1-sol", requestInputTokens: nil, serviceTier: "standard")
        accumulator.add(usage: usage, model: "gpt-6.1-sol", requestInputTokens: 272_001, serviceTier: "standard")
        let restored = try JSONDecoder().decode(TokenCostAccumulator.self, from: JSONEncoder().encode(accumulator))
        XCTAssertEqual(restored.creditEstimate().estimatedCredits, 5)
        XCTAssertEqual(restored.creditEstimate().coveragePercent, 50)
        XCTAssertEqual(restored.billingAssumptions().assumedCreditTokens, 100_000)
        XCTAssertEqual(restored.unpricedUsage().first?.totalTokens, 100_000)
        XCTAssertFalse(restored.requiresRepricing)
    }
}
