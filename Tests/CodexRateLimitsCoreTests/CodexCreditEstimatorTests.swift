import XCTest
@testable import CodexRateLimitsCore

final class CodexCreditEstimatorTests: XCTestCase {
    func testOfficialExampleAndAstraContextException() throws {
        // Official example: 20K input + 80K cached + 5K output = 7.25 credits.
        let example = TokenUsage(inputTokens: 100_000, cachedInputTokens: 80_000,
                                 outputTokens: 5_000, totalTokens: 105_000)
        XCTAssertEqual(try XCTUnwrap(CodexCreditEstimator.estimate(
            usage: example, model: "gpt-5.5", requestInputTokens: 100_000, serviceTier: "standard"
        )), 7.25, accuracy: 0.000_001)
        let astra = TokenUsage(inputTokens: 1_000_000, cachedInputTokens: 400_000,
                              cacheWriteInputTokens: 100_000, outputTokens: 100_000,
                              reasoningOutputTokens: 80_000, totalTokens: 1_100_000)
        for context in [272_000, 272_001, 1_000_000] {
            XCTAssertEqual(try XCTUnwrap(CodexCreditEstimator.estimate(
                usage: astra, model: "gpt-6-astra", requestInputTokens: Int64(context), serviceTier: "default"
            )), 260, accuracy: 0.000_001)
        }
    }

    func testFastAndLongContextAreAppliedPerRequest() throws {
        let usage = TokenUsage(inputTokens: 100_000, outputTokens: 10_000, totalTokens: 110_000)
        for (model, short, long) in [("gpt-5.6-sol", 15.0, 27.5), ("gpt-5.4", 10.0, 18.125)] {
            let fast = model == "gpt-5.4" ? 2.0 : 2.5
            for (context, standard) in [(272_000, short), (272_001, long)] {
                XCTAssertEqual(try XCTUnwrap(CodexCreditEstimator.estimate(
                    usage: usage, model: model, requestInputTokens: Int64(context), serviceTier: "fast"
                )), standard * fast, accuracy: 0.000_001)
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
