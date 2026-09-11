import Foundation
import XCTest
@testable import CodexRateLimitsCore

final class PricingCatalogTests: XCTestCase {
    private let usage = TokenUsage(inputTokens: 1_000_000, totalTokens: 1_000_000)

    private func snapshot(_ edit: (inout PricingDocument) -> Void) throws -> PricingSnapshot {
        var document = PricingCatalog.builtin.document
        edit(&document)
        let validated = try PricingCatalog.decode(JSONEncoder().encode(document))
        return PricingCatalog.snapshot(validated, source: "custom", path: "/fixture/pricing.json", error: nil)
    }

    func testBundledDocumentHasIndependentAuditableCards() {
        let value = PricingCatalog.builtin
        XCTAssertEqual(value.document.schemaVersion, 1)
        XCTAssertEqual(value.metadata.basis, "current-rates")
        XCTAssertEqual(value.metadata.source, "builtin")
        XCTAssertEqual(value.metadata.api.verifiedAt, "2026-09-12")
        XCTAssertTrue(value.metadata.credits.sources.contains { $0.contains("11481834") })
        XCTAssertEqual(value.document.api.models["gpt-6-astra"]?.cacheWriteInput, 12.5)
        XCTAssertEqual(value.document.credits.models["gpt-6-astra"]?.cacheWriteInput, 0)
        XCTAssertNil(value.document.credits.models["gpt-6-astra"]?.contextTier)
    }

    func testCustomCreditsModelDoesNotRequireAnAPIPrice() throws {
        let value = try snapshot {
            $0.credits.models["private-credit-model"] = $0.credits.models["gpt-5.6-sol"]
            $0.credits.aliases["private-alias"] = "private-credit-model"
            $0.api.aliases["private-alias"] = "gpt-5.6-terra"
        }
        PricingCatalog.$current.withValue(value) {
            XCTAssertNil(TokenCostEstimator.estimateUSD(usage: usage, model: "private-credit-model"))
            XCTAssertEqual(CodexCreditEstimator.estimate(usage: usage, model: "private-credit-model", requestInputTokens: 100, serviceTier: "standard"), 100)
            XCTAssertEqual(TokenCostEstimator.estimateUSD(usage: usage, model: "private-alias"), 2)
            XCTAssertEqual(CodexCreditEstimator.estimate(usage: usage, model: "private-alias", requestInputTokens: 100, serviceTier: "standard"), 100)
        }
    }

    func testAliasesAndDatesAreExplicitAndCannotPricePrefixVariants() throws {
        let value = try snapshot {
            $0.api.aliases["local-model"] = "gpt-6-astra"
            $0.api.models["gpt-5.6-terra"]?.datedSnapshots = false
        }
        let card = value.document.api
        XCTAssertEqual(card.canonical("LOCAL-MODEL"), "gpt-6-astra")
        XCTAssertEqual(card.canonical("local-model-2026-09-01"), "gpt-6-astra")
        XCTAssertNil(card.canonical("local-model-pro"))
        XCTAssertNil(card.canonical("gpt-5.6-terra-2026-09-01"))
        XCTAssertEqual(card.canonical("gpt-5.6-terra"), "gpt-5.6-terra")
    }

    func testCyberUnsupportedContextRetainsKnownAmountsAndExactUnknownShare() {
        var accumulator = TokenCostAccumulator()
        accumulator.add(usage: usage, model: "gpt-5.6-cyber", requestInputTokens: 272_000, serviceTier: "standard")
        accumulator.add(usage: TokenUsage(inputTokens: 1, totalTokens: 1), model: "gpt-5.6-cyber", requestInputTokens: 272_001, serviceTier: "standard")
        XCTAssertEqual(accumulator.estimate().estimatedCostUSD, 12.5)
        XCTAssertEqual(accumulator.estimate().unpricedTokens, 1)
        XCTAssertEqual(accumulator.estimate().models.first?.unpricedTokens, 1)
        XCTAssertEqual(accumulator.estimate().unpricedModels, ["gpt-5.6-cyber"])
        XCTAssertEqual(accumulator.unpricedUsage().first?.reason, "unsupportedContext")
        XCTAssertFalse(accumulator.requiresRepricing, "An unsupported request must not cause perpetual replay")
    }

    func testUnknownModelAndModeDetailsSurviveSerializationWithoutDoubleCounting() throws {
        var accumulator = TokenCostAccumulator()
        accumulator.add(usage: TokenUsage(inputTokens: 100, totalTokens: 100), model: "My-Custom-Model", requestInputTokens: 10, serviceTier: "Odd-Mode")
        accumulator.add(usage: TokenUsage(inputTokens: 300, totalTokens: 300), model: "gpt-5.6-sol", requestInputTokens: 10, serviceTier: "Odd-Mode")
        let restored = try JSONDecoder().decode(TokenCostAccumulator.self, from: JSONEncoder().encode(accumulator))
        let entries = restored.unpricedUsage()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.first?.model, "gpt-5.6-sol")
        XCTAssertEqual(entries.first?.serviceTier, "Odd-Mode")
        XCTAssertEqual(entries.first?.percent, 75)
        XCTAssertEqual(entries.first?.reason, "unknownServiceTier")
        XCTAssertEqual(entries.filter { $0.kind == "api" }.reduce(0) { $0 + $1.totalTokens }, 100)
        XCTAssertEqual(entries.filter { $0.kind == "credits" }.reduce(0) { $0 + $1.totalTokens }, 400)
        XCTAssertTrue(entries.contains { $0.model == "My-Custom-Model" && $0.percent == 25 })
    }

    func testManualServiceTierAndContextRulesAreAppliedPerRequest() throws {
        let value = try snapshot {
            $0.credits.models["gpt-5.6-sol"]?.serviceTiers?["local-mode"] = 3
            $0.api.models["gpt-5.6-sol"]?.contextTier?.threshold = 100
            $0.api.models["gpt-5.6-sol"]?.contextTier?.inputMultiplier = 4
        }
        PricingCatalog.$current.withValue(value) {
            XCTAssertEqual(TokenCostEstimator.estimateUSD(usage: usage, model: "gpt-5.6-sol", requestInputTokens: 100), 4)
            XCTAssertEqual(TokenCostEstimator.estimateUSD(usage: usage, model: "gpt-5.6-sol", requestInputTokens: 101), 16)
            XCTAssertEqual(CodexCreditEstimator.estimate(usage: usage, model: "gpt-5.6-sol", requestInputTokens: 101, serviceTier: "LOCAL-MODE"), 300)
        }
    }

    func testEffectiveSignaturesChangeOnlyForAffectedRulesAndAliases() throws {
        let sol = TokenCostEstimator.pricingSignature(for: "gpt-5.6-sol")
        let terra = TokenCostEstimator.pricingSignature(for: "gpt-5.6-terra")
        let alias = TokenCostEstimator.pricingSignature(for: "gpt-daybreak-blue-latest")
        let metadataOnly = try snapshot { $0.api.version = "new-metadata" }
        PricingCatalog.$current.withValue(metadataOnly) { XCTAssertEqual(TokenCostEstimator.pricingSignature(for: "gpt-5.6-sol"), sol) }
        let changed = try snapshot { $0.credits.models["gpt-5.6-sol"]?.input = 101 }
        PricingCatalog.$current.withValue(changed) {
            XCTAssertNotEqual(TokenCostEstimator.pricingSignature(for: "gpt-5.6-sol"), sol)
            XCTAssertEqual(TokenCostEstimator.pricingSignature(for: "gpt-5.6-terra"), terra)
        }
        let mapped = try snapshot { $0.api.aliases["gpt-daybreak-blue-latest"] = "gpt-5.6-terra" }
        PricingCatalog.$current.withValue(mapped) { XCTAssertNotEqual(TokenCostEstimator.pricingSignature(for: "gpt-daybreak-blue-latest"), alias) }
    }

    func testScopeRestoresPreviousPricesAndDoesNotUpgradeStaleTotalsByAppending() throws {
        var accumulator = TokenCostAccumulator()
        accumulator.add(usage: usage, model: "gpt-5.6-sol", requestInputTokens: 100, serviceTier: "standard")
        let changed = try snapshot { $0.api.models["gpt-5.6-sol"]?.input = 8 }
        PricingCatalog.$current.withValue(changed) {
            XCTAssertTrue(accumulator.requiresRepricing)
            accumulator.add(usage: usage, model: "gpt-5.6-sol", requestInputTokens: 100, serviceTier: "standard")
            XCTAssertNil(accumulator.estimate().estimatedCostUSD)
            XCTAssertEqual(accumulator.estimate().unpricedTokens, 2_000_000)
            XCTAssertEqual(accumulator.unpricedUsage().first?.reason, "stalePricing")
        }
        XCTAssertEqual(TokenCostEstimator.estimateUSD(usage: usage, model: "gpt-5.6-sol"), 4)
        XCTAssertTrue(accumulator.requiresRepricing)
        XCTAssertNil(accumulator.estimate().estimatedCostUSD, "Returning to earlier rules must not hide an unpriced appended request")
    }

    func testRejectsInvalidRatesAliasesVersionsAndDates() throws {
        let edits: [(inout PricingDocument) -> Void] = [
            { $0.schemaVersion = 2 }, { $0.api.models["gpt-6-astra"]?.input = -1 },
            { $0.api.models["gpt-6-astra"]?.contextTier?.threshold = 0 },
            { $0.api.models["gpt-6-astra"]?.contextTier?.outputMultiplier = 0 },
            { $0.api.aliases["a"] = "b"; $0.api.aliases["b"] = "a" },
            { $0.api.aliases["gpt-6-astra"] = "gpt-5.6-sol" }, { $0.api.aliases["bad"] = "absent" },
            { $0.api.aliases["UPPER"] = "gpt-6-astra" }, { $0.api.version = "" },
            { $0.api.verifiedAt = "2026-02-30" }, { $0.api.sources = ["javascript:alert(1)"] },
            { $0.api.conditions = [] }, { $0.api.models["gpt-6-astra"]?.serviceTiers = ["standard": 1] },
            { $0.credits.models["gpt-6-astra"]?.serviceTiers?["standard"] = 2 },
            { $0.credits.models["gpt-6-astra"]?.serviceTiers?["fast"] = -1 }
        ]
        for (index, edit) in edits.enumerated() { XCTAssertThrowsError(try snapshot(edit), "invalid case \(index)") }
    }

    func testRejectsMisspelledKeysWrongTypesAndOversizedFiles() throws {
        let data = try JSONEncoder().encode(PricingCatalog.builtin.document)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for invalid in [text.replacingOccurrences(of: "\"input\":", with: "\"imput\":"),
                        text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true"),
                        text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"unexpected\":true")] {
            XCTAssertThrowsError(try PricingCatalog.decode(Data(invalid.utf8)))
        }
        XCTAssertThrowsError(try PricingCatalog.decode(Data(repeating: 32, count: PricingCatalog.maximumBytes + 1)))
    }

    func testInvalidExplicitConfigFallsBackVisiblyAndRecoversOnNextLoad() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("pricing.json")
        let environment = ["CODEX_PRICING_FILE": file.path]
        let absent = PricingCatalog.load(environment: environment)
        XCTAssertEqual(absent.metadata.source, "builtin")
        XCTAssertNotNil(absent.metadata.configurationError)
        try Data("{invalid".utf8).write(to: file)
        XCTAssertNotNil(PricingCatalog.load(environment: environment).metadata.configurationError)
        try JSONEncoder().encode(PricingCatalog.builtin.document).write(to: file, options: .atomic)
        let restored = PricingCatalog.load(environment: environment)
        XCTAssertNil(restored.metadata.configurationError)
        XCTAssertEqual(restored.metadata.source, "custom")
        XCTAssertEqual(restored.metadata.fingerprint, PricingCatalog.builtin.metadata.fingerprint)
    }

    func testDuplicateKeysCannotSilentlySelectAConflictingPrice() throws {
        let text = String(decoding: try JSONEncoder().encode(PricingCatalog.builtin.document), as: UTF8.self)
        for key in ["schemaVersion", #"\u0073chemaVersion"#] {
            let duplicate = text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"\(key)\":1")
            XCTAssertThrowsError(try PricingCatalog.decode(Data(duplicate.utf8)))
        }
        // Repeated keys in distinct model objects are valid, including braces
        // and escaped quotation marks in ordinary descriptive strings.
        var document = PricingCatalog.builtin.document
        document.api.conditions.append("Example: {\"input\": \"quoted\"}; backslash \\")
        XCTAssertNoThrow(try PricingCatalog.decode(JSONEncoder().encode(document)))
    }
}
