import XCTest
@testable import CodexRateLimitsCore

final class CodexCreditEstimatorTests: XCTestCase {
    func testPurchasedCreditModesUseIndependentKnownAmounts() throws {
        let usage = TokenUsage(inputTokens: 100_000, cachedInputTokens: 80_000,
                               outputTokens: 5_000, totalTokens: 105_000)
        // Hand-calculated from the published token rates, independent of the card.
        let cases: [(String, Double, Double)] = [
            ("gpt-6.1-sol", 2.45, 4.90), ("gpt-6-sol", 2.65, 5.30),
            ("gpt-6-luna", 0.1325, 0.265), ("gpt-6-astra", 13.25, 26.50),
            ("gpt-5.6-sol", 5.30, 10.60), ("gpt-5.6-terra", 2.90, 5.80),
            ("gpt-5.6-luna", 0.29, 0.58), ("gpt-5.5", 7.25, 14.50),
            ("gpt-5.4", 3.625, 7.25)
        ]
        for (model, standard, fast) in cases {
            for (tier, expected) in [("standard", standard), ("default", standard), (" FAST ", fast), ("priority", fast)] {
                XCTAssertEqual(try XCTUnwrap(CodexCreditEstimator.estimate(
                    usage: usage, model: model, requestInputTokens: 100_000, serviceTier: tier
                )), expected, accuracy: 1e-12, "\(model) / \(tier)")
            }
        }
    }

    func testUltrafastIsExplicitlyPricedOnlyForAstraAndAPIStaysStandard() throws {
        let usage = TokenUsage(inputTokens: 100_000, cachedInputTokens: 80_000,
                               outputTokens: 5_000, totalTokens: 105_000)
        var accumulator = TokenCostAccumulator()
        accumulator.add(usage: usage, model: "gpt-6-astra", requestInputTokens: 100_000, serviceTier: "ultrafast")
        XCTAssertEqual(try XCTUnwrap(accumulator.creditEstimate().estimatedCredits), 79.50, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(accumulator.estimate().estimatedCostUSD), 0.53, accuracy: 1e-12)
        XCTAssertTrue(accumulator.unpricedUsage().isEmpty)
        for model in ["gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol"] {
            XCTAssertNil(CodexCreditEstimator.estimate(usage: usage, model: model,
                                                      requestInputTokens: 100_000, serviceTier: "ultrafast"))
            XCTAssertEqual(CodexCreditEstimator.unpricedReason(usage: usage, model: model, requestInputTokens: 100_000,
                                                              serviceTier: "ultrafast"), "unknownServiceTier")
        }
    }

    func testGPT61SolLongContextCreditsRemainUnpricedForBothModes() {
        let usage = TokenUsage(inputTokens: 272_001, cachedInputTokens: 80_000,
                               outputTokens: 5_000, totalTokens: 277_001)
        for tier in ["standard", "fast"] {
            XCTAssertNil(CodexCreditEstimator.estimate(usage: usage, model: "gpt-6.1-sol",
                requestInputTokens: 272_001, serviceTier: tier))
        }
    }

    func testPublishedRatesAndAstraWriteUncertaintyStayIndependent() throws {
        let example = TokenUsage(inputTokens: 100_000, cachedInputTokens: 80_000,
                                 outputTokens: 5_000, totalTokens: 105_000)
        XCTAssertEqual(try XCTUnwrap(CodexCreditEstimator.estimate(
            usage: example, model: "gpt-5.5", requestInputTokens: 100_000, serviceTier: "standard"
        )), 7.25, accuracy: 0.000_001)
        let writes = TokenUsage(inputTokens: 100_000, cacheWriteInputTokens: 100_000, totalTokens: 100_000)
        for context in [272_000, 272_001, 1_000_000] {
            XCTAssertNil(CodexCreditEstimator.estimate(usage: writes, model: "gpt-6-astra",
                requestInputTokens: Int64(context), serviceTier: "default"))
        }
    }

    func testFastPricingAndCoverageAreAppliedPerRequest() throws {
        let usage = TokenUsage(inputTokens: 100_000, outputTokens: 10_000, totalTokens: 110_000)
        for (model, short) in [("gpt-5.6-sol", 15.0), ("gpt-5.4", 10.0)] {
            XCTAssertEqual(try XCTUnwrap(CodexCreditEstimator.estimate(
                usage: usage, model: model, requestInputTokens: 272_000, serviceTier: "fast"
            )), short * 2, accuracy: 0.000_001)
            XCTAssertNil(CodexCreditEstimator.estimate(usage: usage, model: model,
                requestInputTokens: 272_001, serviceTier: "fast"))
        }
    }

    func testGPT6SolAndLunaCreditRatesUseStandardTokensAndFastMultiplier() throws {
        let usage = TokenUsage(inputTokens: 100_000, cachedInputTokens: 40_000,
                               outputTokens: 10_000, totalTokens: 110_000)
        for (model, standard) in [("gpt-6-sol", 5.7), ("gpt-6-luna", 0.285)] {
            for (tier, multiplier) in [("standard", 1.0), ("fast", 2.0)] {
                XCTAssertEqual(try XCTUnwrap(CodexCreditEstimator.estimate(
                    usage: usage, model: model, requestInputTokens: 100_000, serviceTier: tier
                )), standard * multiplier, accuracy: 0.000_001)
            }
        }
    }

    func testCreditsHaveIndependentCoverageAndKeepKnownAmounts() throws {
        var accumulator = TokenCostAccumulator()
        let usage = TokenUsage(inputTokens: 1_000_000, totalTokens: 1_000_000)
        accumulator.add(usage: usage, model: "gpt-5.6-sol", requestInputTokens: 100_000)
        accumulator.add(usage: usage, model: "gpt-5.6-sol", requestInputTokens: 100_000, serviceTier: "unsupported-tier")
        accumulator.add(usage: usage, model: "gpt-5.1-codex", requestInputTokens: 100_000, serviceTier: "default")
        XCTAssertEqual(accumulator.estimate().coveragePercent, 100)
        let credits = accumulator.creditEstimate()
        XCTAssertEqual(credits.estimatedCredits, 100)
        XCTAssertEqual(credits.pricedTokens, 1_000_000)
        XCTAssertEqual(credits.unpricedTokens, 2_000_000)
        XCTAssertEqual(credits.assumedStandardTokens, 1_000_000)
        XCTAssertEqual(Set(credits.unpricedModels), ["gpt-5.6-sol", "gpt-5.1-codex"])
    }

    func testDaybreakAliasesRetainIdentityAndUnknownVariantsStayUnpriced() throws {
        XCTAssertEqual(TokenCostEstimator.canonicalModel("gpt-daybreak-blue-latest"), "gpt-5.6-sol")
        XCTAssertEqual(TokenCostEstimator.canonicalModel("gpt-daybreak-red-latest"), "gpt-5.6-cyber")
        for model in ["gpt-5.3-codex-spark", "gpt-5.5-pro", "gpt-5.6-sol-experimental", "gpt-5.4-mini-unknown"] {
            XCTAssertNil(TokenCostEstimator.canonicalModel(model))
        }
        var accumulator = TokenCostAccumulator()
        accumulator.add(usage: TokenUsage(inputTokens: 1_000_000, totalTokens: 1_000_000),
                        model: "gpt-daybreak-blue-latest", requestInputTokens: 100_000, serviceTier: "standard")
        XCTAssertEqual(accumulator.estimate().models.first?.model, "gpt-daybreak-blue-latest")
        XCTAssertEqual(accumulator.estimate().estimatedCostUSD, 4)
        XCTAssertEqual(accumulator.creditEstimate().estimatedCredits, 100)
        XCTAssertFalse(accumulator.requiresRepricing)
    }

    func testOldPricedCacheDoesNotClaimCurrentCoverage() throws {
        let data = Data(#"{"buckets":{"gpt-5.3-codex":{"usage":{"inputTokens":100,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":0,"reasoningOutputTokens":0,"totalTokens":100},"estimatedCostUSD":1000}}}"#.utf8)
        var accumulator = try JSONDecoder().decode(TokenCostAccumulator.self, from: data)
        XCTAssertTrue(accumulator.requiresRepricing)
        accumulator.add(usage: TokenUsage(inputTokens: 100, totalTokens: 100), model: "gpt-5.3-codex", requestInputTokens: 100)
        XCTAssertNil(accumulator.estimate().estimatedCostUSD)
        XCTAssertEqual(accumulator.estimate().unpricedTokens, 200)
        XCTAssertNil(accumulator.creditEstimate().estimatedCredits)
        XCTAssertEqual(accumulator.creditEstimate().unpricedTokens, 200)
    }

    func testBalanceDistinguishesMissingZeroNegativeAndUnlimited() {
        XCTAssertTrue(AppText.officialCreditsBalance(nil).contains("--"))
        XCTAssertTrue(AppText.officialCreditsBalance(CreditsSnapshot(hasCredits: false, unlimited: false, balance: "0")).hasSuffix("0"))
        XCTAssertTrue(AppText.officialCreditsBalance(CreditsSnapshot(hasCredits: true, unlimited: true, balance: nil)).contains("∞"))
        XCTAssertTrue(AppText.officialCreditsBalance(CreditsSnapshot(hasCredits: false, unlimited: false, balance: "-12.5")).contains("-12.5"))
        XCTAssertTrue(AppText.officialCreditsBalance(CreditsSnapshot(hasCredits: false, unlimited: false, balance: "invalid")).contains("--"))
    }
}
