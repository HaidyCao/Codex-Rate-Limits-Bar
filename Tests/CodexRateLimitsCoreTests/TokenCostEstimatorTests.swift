import XCTest
@testable import CodexRateLimitsCore

final class TokenCostEstimatorTests: XCTestCase {
    func testCyberAPIMixedInputAndReasoningUseThePublishedContextTier() throws {
        let models = ["gpt-5.6-cyber", " GPT-5.6-CYBER ", "gpt-daybreak-red-latest", "gpt-5.6-cyber-2026-08-01"]
        for (input, expected) in [(Int64(272_000), 2.9375), (272_001, 5.687525), (400_000, 8.8875)] {
            let usage = TokenUsage(inputTokens: input, cachedInputTokens: 80_000, cacheWriteInputTokens: 20_000,
                outputTokens: 5_000, reasoningOutputTokens: 4_000, totalTokens: input + 5_000)
            for model in models {
                XCTAssertEqual(try XCTUnwrap(TokenCostEstimator.estimateUSD(usage: usage, model: model,
                    requestInputTokens: input)), expected, accuracy: 1e-12, "\(model), \(input)")
            }
        }
    }

    func testCyberAPICacheReadsAndWritesScaleOnceAtTheContextBoundary() throws {
        for (input, cachedCost, writeCost) in [(Int64(272_000), 0.34, 4.25), (272_001, 0.6800025, 8.50003125)] {
            let read = TokenUsage(inputTokens: input, cachedInputTokens: input, totalTokens: input)
            let write = TokenUsage(inputTokens: input, cacheWriteInputTokens: input, totalTokens: input)
            for (usage, expected) in [(read, cachedCost), (write, writeCost)] {
                XCTAssertEqual(try XCTUnwrap(TokenCostEstimator.estimateUSD(usage: usage, model: "gpt-5.6-cyber",
                    requestInputTokens: input)), expected, accuracy: 1e-12)
            }
        }
    }

    func testCyberMissingContextRemainsAssumedAndCreditCoverageStaysIndependent() throws {
        let usage = TokenUsage(inputTokens: 100_000, cachedInputTokens: 80_000,
            outputTokens: 5_000, totalTokens: 105_000)
        var missing = TokenCostAccumulator()
        missing.add(usage: usage, model: "gpt-daybreak-red-latest", requestInputTokens: nil, serviceTier: "standard")
        XCTAssertEqual(try XCTUnwrap(missing.estimate().estimatedCostUSD), 0.725, accuracy: 1e-12)
        XCTAssertEqual(missing.billingAssumptions().assumedAPITokens, 105_000)
        XCTAssertEqual(missing.billingAssumptions().missingRequestContextTokens, 105_000)
        XCTAssertEqual(missing.billingAssumptions().missingServiceTierTokens, 0)
        XCTAssertEqual(try XCTUnwrap(missing.creditEstimate().estimatedCredits), 18.125, accuracy: 1e-12)

        // The cumulative delta is smaller than the last request's full context.
        var long = TokenCostAccumulator()
        long.add(usage: usage, model: "gpt-daybreak-red-latest", requestInputTokens: 272_001, serviceTier: "standard")
        XCTAssertEqual(try XCTUnwrap(long.estimate().estimatedCostUSD), 1.2625, accuracy: 1e-12)
        XCTAssertEqual(long.billingAssumptions().assumedAPITokens, 0)
        XCTAssertNil(long.creditEstimate().estimatedCredits)
        XCTAssertEqual(long.unpricedUsage().map(\.kind), ["credits"])
        XCTAssertEqual(long.unpricedUsage().map(\.reason), ["unsupportedContext"])
        XCTAssertFalse(long.requiresRepricing)
        for model in ["gpt-5.6-cyber-pro", "gpt-5.6-cyber-latest", "gpt-daybreak-red", "gpt-daybreak-red-experimental"] {
            XCTAssertNil(TokenCostEstimator.estimateUSD(usage: usage, model: model, requestInputTokens: 272_001), model)
        }
    }

    func testGPT61SolAPIUsesItsOwnCachedRateAndRequestContextBoundary() throws {
        for (input, expected) in [(Int64(100_000), 0.098), (272_000, 0.442), (272_001, 0.859004)] {
            let usage = TokenUsage(inputTokens: input, cachedInputTokens: 80_000,
                                   outputTokens: 5_000, reasoningOutputTokens: 4_000, totalTokens: input + 5_000)
            XCTAssertEqual(try XCTUnwrap(TokenCostEstimator.estimateUSD(
                usage: usage, model: "gpt-6.1-sol", requestInputTokens: input
            )), expected, accuracy: 1e-12)
        }
    }

    func testGPT61SolAPICacheWritesAreChargedOnceAndScaleWithContext() throws {
        for input in [Int64(272_000), 272_001] {
            let usage = TokenUsage(inputTokens: input, cacheWriteInputTokens: input, totalTokens: input)
            let expected = input == 272_000 ? 0.68 : 1.360005
            XCTAssertEqual(try XCTUnwrap(TokenCostEstimator.estimateUSD(
                usage: usage, model: "gpt-6.1-sol", requestInputTokens: input
            )), expected, accuracy: 1e-12)
        }
    }

    func testGPT61SolOnlyResolvesPublishedModelName() {
        for card in [PricingCatalog.builtin.document.api, PricingCatalog.builtin.document.credits] {
            XCTAssertEqual(card.canonical(" GPT-6.1-SOL \n"), "gpt-6.1-sol")
            for name in ["gpt-6.1", "gpt-6.1-sol-latest", "gpt-6.1-sol-pro", "gpt-6.1-sol-2026-09-29"] {
                XCTAssertNil(card.canonical(name), name)
            }
        }
    }

    func testGPT61SolMissingContextAndModeRemainVisibleAssumptions() throws {
        var accumulator = TokenCostAccumulator()
        accumulator.add(usage: TokenUsage(inputTokens: 100_000, cachedInputTokens: 80_000,
                                         outputTokens: 5_000, totalTokens: 105_000),
                        model: "gpt-6.1-sol", requestInputTokens: nil)
        XCTAssertEqual(try XCTUnwrap(accumulator.estimate().estimatedCostUSD), 0.098, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(accumulator.creditEstimate().estimatedCredits), 2.45, accuracy: 1e-12)
        XCTAssertEqual(accumulator.creditEstimate().assumedStandardTokens, 105_000)
        XCTAssertEqual(accumulator.billingAssumptions().assumedAPITokens, 105_000)
        XCTAssertEqual(accumulator.billingAssumptions().assumedCreditTokens, 105_000)
    }

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

    func testGPT6SolAndLunaAPIPricesAtLongContextBoundary() throws {
        let usage = TokenUsage(
            inputTokens: 1_000_000,
            cachedInputTokens: 400_000,
            cacheWriteInputTokens: 100_000,
            outputTokens: 100_000,
            reasoningOutputTokens: 80_000,
            totalTokens: 1_100_000
        )
        let cases: [(String, Double, Double)] = [
            ("gpt-6-sol", 2.33, 4.16),
            ("gpt-6-luna", 0.1165, 0.208)
        ]

        for (model, short, long) in cases {
            for (requestInput, expected) in [(Int64?(272_000), short), (Int64?(272_001), long)] {
                let cost = try XCTUnwrap(TokenCostEstimator.estimateUSD(
                    usage: usage,
                    model: model,
                    requestInputTokens: requestInput
                ))
                XCTAssertEqual(cost, expected, accuracy: 0.000_000_1, "\(model) at \(requestInput ?? 0) input tokens")
            }
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
