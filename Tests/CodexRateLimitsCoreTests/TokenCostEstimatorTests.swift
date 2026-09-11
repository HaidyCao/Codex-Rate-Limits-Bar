import XCTest
@testable import CodexRateLimitsCore

final class TokenCostEstimatorTests: XCTestCase {
    func testAstraPricingAtLongContextBoundary() throws {
        let usage = TokenUsage(
            inputTokens: 1_000_000,
            cachedInputTokens: 400_000,
            cacheWriteInputTokens: 100_000,
            outputTokens: 100_000,
            reasoningOutputTokens: 80_000,
            totalTokens: 1_100_000
        )
        let cases: [(Int64?, Double)] = [(nil, 11.65), (272_000, 11.65), (272_001, 20.80)]
        for (requestInput, expected) in cases {
            let cost = try XCTUnwrap(TokenCostEstimator.estimateUSD(
                usage: usage,
                model: "gpt-6-astra",
                requestInputTokens: requestInput
            ))
            XCTAssertEqual(cost, expected, accuracy: 0.000_000_1)
        }
    }

    func testAstraModelNamesDoNotPriceUnknownVariants() {
        for model in ["gpt-6-astra", " GPT-6-ASTRA ", "gpt-6-astra-2026-09-03"] {
            XCTAssertEqual(TokenCostEstimator.canonicalModel(model), "gpt-6-astra")
        }
        for model in ["gpt-6", "gpt-6-mini", "gpt-6-astra-pro", "gpt-6-astra-experimental"] {
            XCTAssertNil(TokenCostEstimator.canonicalModel(model))
        }
    }

    func testNewPricedEventDoesNotHideUnpricedCachedHistory() throws {
        let data = Data(#"{"buckets":{"gpt-6-astra":{"usage":{"inputTokens":100,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":0,"reasoningOutputTokens":0,"totalTokens":100}}}}"#.utf8)
        var accumulator = try JSONDecoder().decode(TokenCostAccumulator.self, from: data)
        XCTAssertTrue(accumulator.hasNewlyPricedModels)
        accumulator.add(
            usage: TokenUsage(inputTokens: 100, totalTokens: 100),
            model: "gpt-6-astra",
            requestInputTokens: 100
        )
        let estimate = accumulator.estimate()
        XCTAssertNil(estimate.estimatedCostUSD)
        XCTAssertEqual(estimate.unpricedTokens, 200)
        XCTAssertEqual(estimate.coveragePercent, 0)
        XCTAssertTrue(accumulator.hasNewlyPricedModels)
    }

    func testStandardPricingSeparatesCachedAndCacheWriteInput() throws {
        let usage = TokenUsage(
            inputTokens: 1_000_000,
            cachedInputTokens: 400_000,
            cacheWriteInputTokens: 100_000,
            outputTokens: 100_000,
            reasoningOutputTokens: 80_000,
            totalTokens: 1_100_000
        )

        let cost = try XCTUnwrap(TokenCostEstimator.estimateUSD(
            usage: usage,
            model: "gpt-5.6-luna",
            requestInputTokens: 200_000
        ))

        XCTAssertEqual(usage.uncachedInputTokens, 500_000)
        XCTAssertEqual(cost, 0.253, accuracy: 0.000_000_1)
    }

    func testLongContextTierUsesRequestInputAndScalesOutput() throws {
        let usage = TokenUsage(
            inputTokens: 100_000,
            outputTokens: 10_000,
            totalTokens: 110_000
        )

        let cost = try XCTUnwrap(TokenCostEstimator.estimateUSD(
            usage: usage,
            model: "gpt-5.6-sol",
            requestInputTokens: 300_000
        ))

        XCTAssertEqual(cost, 1.10, accuracy: 0.000_000_1)
    }

    func testReasoningTokensAreNotChargedTwice() throws {
        let usage = TokenUsage(
            outputTokens: 100_000,
            reasoningOutputTokens: 80_000,
            totalTokens: 100_000
        )

        let cost = try XCTUnwrap(TokenCostEstimator.estimateUSD(
            usage: usage,
            model: "gpt-5.6-luna"
        ))

        XCTAssertEqual(cost, 0.12, accuracy: 0.000_000_1)
    }

    func testCanonicalModelSupportsAliasesAndSnapshots() {
        XCTAssertEqual(TokenCostEstimator.canonicalModel("GPT-5.6"), "gpt-5.6-sol")
        XCTAssertEqual(TokenCostEstimator.canonicalModel("gpt-5.6-latest"), "gpt-5.6-sol")
        XCTAssertEqual(TokenCostEstimator.canonicalModel("gpt-5.6-2026-08-01"), "gpt-5.6-sol")
        XCTAssertEqual(TokenCostEstimator.canonicalModel("gpt-5.6-terra-2026-08-01"), "gpt-5.6-terra")
        XCTAssertNil(TokenCostEstimator.canonicalModel("community-model"))
    }

    func testAccumulatorReportsPartialPriceCoverage() throws {
        var accumulator = TokenCostAccumulator()
        accumulator.add(
            usage: TokenUsage(inputTokens: 100, totalTokens: 100),
            model: "gpt-5.6-luna",
            requestInputTokens: 100
        )
        accumulator.add(
            usage: TokenUsage(inputTokens: 300, totalTokens: 300),
            model: "community-model",
            requestInputTokens: 300
        )

        let estimate = accumulator.estimate()

        XCTAssertEqual(try XCTUnwrap(estimate.estimatedCostUSD), 0.000_02, accuracy: 0.000_000_001)
        XCTAssertEqual(estimate.coveragePercent, 25, accuracy: 0.000_001)
        XCTAssertEqual(estimate.pricedTokens, 100)
        XCTAssertEqual(estimate.unpricedTokens, 300)
        XCTAssertTrue(estimate.isPartial)
        XCTAssertEqual(estimate.models.map(\.model), ["community-model", "gpt-5.6-luna"])
    }

    func testUSDFormatterHandlesSmallAndUnavailableValues() {
        XCTAssertEqual(USDFormatter.string(nil), "--")
        XCTAssertEqual(USDFormatter.string(0.001), "<$0.01")
        XCTAssertEqual(USDFormatter.string(1_234.5), "$1,234.50")
    }
}
