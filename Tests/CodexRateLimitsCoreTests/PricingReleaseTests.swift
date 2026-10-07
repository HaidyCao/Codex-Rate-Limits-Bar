import XCTest
@testable import CodexRateLimitsCore

// Release examples are hand-calculated expectations, never generated from the
// bundled document. See docs/pricing.md for sources, review gaps and arithmetic.
final class PricingReleaseTests: XCTestCase {
    func testStandardReleaseExamplesCoverEveryRetainedModel() throws {
        let examples: [(String, Double, Double?)] = [
            ("gpt-6-astra", 0.53, 13.25),
            ("gpt-6.1-sol", 0.098, 2.45),
            ("gpt-6-sol", 0.106, 2.65),
            ("gpt-6-luna", 0.0053, 0.1325),
            ("gpt-5.6-sol", 0.212, 5.3),
            ("gpt-5.6-terra", 0.116, 2.9),
            ("gpt-5.6-luna", 0.0116, 0.29),
            ("gpt-5.6-cyber", 0.725, 18.125),
            ("gpt-5.5", 0.29, 7.25),
            ("gpt-5.4", 0.145, 3.625),
            ("gpt-5.4-mini", 0.0435, 1.09),
            ("gpt-5.3-codex", 0.119, 2.975),
            ("gpt-5.3-chat-latest", 0.119, nil),
            ("gpt-5.2-codex", 0.119, nil),
            ("gpt-5.2-chat-latest", 0.119, nil),
            ("gpt-5.2", 0.119, 2.975),
            ("gpt-5.1-codex-max", 0.085, nil),
            ("gpt-5.1-codex-mini", 0.017, nil),
            ("gpt-5.1-codex", 0.085, nil),
            ("gpt-5-codex", 0.085, nil),
            ("gpt-5", 0.085, nil)
        ]
        let builtin = PricingCatalog.builtin
        XCTAssertEqual(Set(examples.map { $0.0 }), Set(builtin.document.api.models.keys))
        XCTAssertEqual(Set(examples.filter { $0.2 != nil }.map { $0.0 }), Set(builtin.document.credits.models.keys))
        let usage = TokenUsage(inputTokens: 100_000, cachedInputTokens: 80_000,
                               outputTokens: 5_000, totalTokens: 105_000)
        try PricingCatalog.$current.withValue(builtin) {
            for (model, api, credits) in examples {
                XCTAssertEqual(try XCTUnwrap(TokenCostEstimator.estimateUSD(usage: usage, model: model,
                    requestInputTokens: 100_000)), api, accuracy: 1e-12, model)
                let actual = CodexCreditEstimator.estimate(usage: usage, model: model,
                    requestInputTokens: 100_000, serviceTier: "standard")
                if let credits { XCTAssertEqual(try XCTUnwrap(actual), credits, accuracy: 1e-12, model) }
                else { XCTAssertNil(actual, model) }
            }
        }
    }

    func testPurchasedCreditModesUseIndependentAmountsAndExplicitCoverage() throws {
        let examples: [(String, Double)] = [
            ("gpt-6-astra", 26.5), ("gpt-6.1-sol", 4.9), ("gpt-6-sol", 5.3),
            ("gpt-6-luna", 0.265), ("gpt-5.6-sol", 10.6), ("gpt-5.6-terra", 5.8),
            ("gpt-5.6-luna", 0.58), ("gpt-5.5", 14.5), ("gpt-5.4", 7.25)
        ]
        let usage = TokenUsage(inputTokens: 100_000, cachedInputTokens: 80_000,
                               outputTokens: 5_000, totalTokens: 105_000)
        try PricingCatalog.$current.withValue(PricingCatalog.builtin) {
            for (model, expected) in examples {
                for mode in ["fast", "priority"] {
                    XCTAssertEqual(try XCTUnwrap(CodexCreditEstimator.estimate(usage: usage, model: model,
                        requestInputTokens: 100_000, serviceTier: mode)), expected, accuracy: 1e-12, model)
                }
            }
            XCTAssertEqual(try XCTUnwrap(CodexCreditEstimator.estimate(usage: usage, model: "gpt-6-astra",
                requestInputTokens: 100_000, serviceTier: "ultrafast")), 79.5, accuracy: 1e-12)
            for (model, rate) in PricingCatalog.builtin.document.credits.models {
                let modes = model == "gpt-6-astra" ? ["standard", "default", "fast", "priority", "ultrafast"]
                    : examples.contains { $0.0 == model } ? ["standard", "default", "fast", "priority"] : ["standard", "default"]
                XCTAssertEqual(Set(rate.serviceTiers?.keys.map { $0 } ?? []), Set(modes), model)
            }
        }
    }
}
