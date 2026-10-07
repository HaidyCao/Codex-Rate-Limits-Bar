import XCTest
@testable import CodexRateLimitsCore

final class PricingHealthTests: XCTestCase {
    private func custom(_ edit: (inout PricingDocument) -> Void) throws -> PricingSnapshot {
        var document = PricingCatalog.builtin.document
        edit(&document)
        return PricingCatalog.snapshot(try PricingCatalog.decode(JSONEncoder().encode(document)),
                                       source: "custom", path: "/fixture/pricing.json", error: nil)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    func testBuiltinAndMetadataOnlyChangesHaveNoCoverageOrRateDifferences() throws {
        let snapshot = try custom {
            $0.api.version = "my-contract"
            $0.credits.verifiedAt = "2026-10-01"
            $0.credits.sources = ["https://example.invalid/contract"]
        }
        for value in [PricingCatalog.builtin, snapshot] {
            let report = PricingHealth.report(value)
            XCTAssertEqual(report.configurationStatus, "valid")
            for card in [report.api, report.credits] {
                XCTAssertFalse(card.coverageReviewRecommended)
                XCTAssertTrue(card.rateDifferences.isEmpty)
                XCTAssertTrue(card.resolutionDifferences.isEmpty)
            }
        }
        XCTAssertEqual(PricingHealth.report(snapshot).active.api.version, "my-contract")
    }

    func testMissingNewModelDoesNotInvalidateOrReplaceAnIntentionalCustomPrice() throws {
        let snapshot = try custom {
            $0.api.models.removeValue(forKey: "gpt-6.1-sol")
            $0.credits.models.removeValue(forKey: "gpt-6.1-sol")
            $0.api.models["gpt-6-sol"]?.input = 7
        }
        let report = PricingHealth.report(snapshot)
        XCTAssertEqual(report.configurationStatus, "valid")
        XCTAssertNil(report.active.configurationError)
        XCTAssertEqual(report.active.source, "custom")
        XCTAssertEqual(report.api.missingModels, ["gpt-6.1-sol"])
        XCTAssertEqual(report.credits.missingModels, ["gpt-6.1-sol"])
        XCTAssertTrue(report.api.coverageReviewRecommended)
        XCTAssertEqual(report.api.rateDifferences.map(\.model), ["gpt-6-sol"])
        XCTAssertEqual(report.api.rateDifferences.first?.builtinRate.input, 2)
        XCTAssertEqual(report.api.rateDifferences.first?.activeRate.input, 7)
        PricingCatalog.$current.withValue(snapshot) {
            let usage = TokenUsage(inputTokens: 100_000, totalTokens: 100_000)
            XCTAssertEqual(TokenCostEstimator.estimateUSD(usage: usage, model: "gpt-6-sol"), 0.7)
            XCTAssertNil(TokenCostEstimator.estimateUSD(usage: usage, model: "gpt-6.1-sol"))
        }
    }

    func testModesAndPolicyDifferencesRemainInformationalAndIndependentlyScoped() throws {
        let snapshot = try custom {
            $0.credits.models["gpt-6-astra"]?.serviceTiers?.removeValue(forKey: "ultrafast")
            $0.credits.models["gpt-6.1-sol"]?.serviceTiers?["fast"] = 4
            $0.credits.models["gpt-6.1-sol"]?.serviceTiers?["private-mode"] = 3
            $0.credits.models["gpt-6.1-sol"]?.cacheWriteInputUnverified = nil
            $0.credits.models["gpt-6.1-sol"]?.maximumInputTokens = nil
            $0.api.models["gpt-6.1-sol"]?.datedSnapshots = true
            $0.api.models["gpt-6.1-sol"]?.contextTier?.threshold = 300_000
        }
        let report = PricingHealth.report(snapshot)
        XCTAssertFalse(report.api.coverageReviewRecommended)
        XCTAssertEqual(report.credits.missingServiceTiers.map(\.model), ["gpt-6-astra"])
        XCTAssertEqual(report.credits.missingServiceTiers.first?.serviceTiers, ["ultrafast"])
        XCTAssertEqual(report.credits.rateDifferences.map(\.model), ["gpt-6-astra", "gpt-6.1-sol"])
        XCTAssertEqual(report.api.rateDifferences.first?.activeRate.contextTier?.threshold, 300_000)
        XCTAssertEqual(report.configurationStatus, "valid")
    }

    func testAliasCoverageUsesActualResolutionAndReportsChangedTargets() throws {
        let snapshot = try custom {
            $0.api.models["private-sol"] = $0.api.models.removeValue(forKey: "gpt-6.1-sol")
            $0.api.aliases["gpt-6.1-sol"] = "private-sol"
            $0.credits.aliases.removeValue(forKey: "gpt-5.6-latest")
            $0.credits.aliases["gpt-daybreak-blue-latest"] = "gpt-6-luna"
            $0.api.models["gpt-5.6"] = $0.api.models["gpt-5.6-sol"]
            $0.api.aliases.removeValue(forKey: "gpt-5.6")
            $0.api.aliases["private-alias"] = "private-sol"
        }
        let report = PricingHealth.report(snapshot)
        XCTAssertTrue(report.api.missingModels.isEmpty)
        XCTAssertTrue(report.api.missingAliases.isEmpty)
        XCTAssertEqual(report.api.additionalModels, ["private-sol"])
        XCTAssertEqual(report.api.additionalAliases, ["private-alias"])
        XCTAssertEqual(report.api.resolutionDifferences.map(\.name), ["gpt-5.6", "gpt-6.1-sol"])
        XCTAssertTrue(report.api.rateDifferences.isEmpty)
        XCTAssertEqual(report.credits.missingAliases, ["gpt-5.6-latest"])
        XCTAssertEqual(report.credits.resolutionDifferences.first?.activeModel, "gpt-6-luna")
        XCTAssertEqual(report.credits.rateDifferences.map(\.model), ["gpt-daybreak-blue-latest"])
    }

    func testReviewBoundariesNeverExpirePricesOrRemoveHistoricalModels() throws {
        let snapshot = PricingCatalog.builtin
        let fingerprint = snapshot.metadata.fingerprint
        for (timestamp, retirementDue, promotionDue) in [
            ("2026-10-13T23:59:59Z", false, false),
            ("2026-10-14T00:00:00Z", true, false),
            ("2026-11-20T23:59:59Z", true, false),
            ("2026-11-21T00:00:00Z", true, true),
            ("2027-01-01T00:00:00Z", true, true)
        ] {
            let report = PricingHealth.report(snapshot, now: date(timestamp))
            XCTAssertEqual(report.checkedOn, String(timestamp.prefix(10)))
            XCTAssertEqual(report.builtinPolicyReviews.map(\.reviewDue), [retirementDue, promotionDue])
            XCTAssertEqual(report.builtinPolicyReviews.first?.announcedProductChangeOn, "2026-10-14")
            for review in report.builtinPolicyReviews {
                XCTAssertEqual(review.verifiedAt, "2026-10-06")
                XCTAssertNil(review.priceEffectiveOn)
                XCTAssertNil(review.priceExpiresOn)
            }
            XCTAssertEqual(report.active.fingerprint, fingerprint)
            XCTAssertTrue(report.api.missingModels.isEmpty)
            XCTAssertTrue(report.api.rateDifferences.isEmpty)
            XCTAssertEqual(snapshot.document.api.models["gpt-5.6-sol"]?.input, 4)
            XCTAssertEqual(snapshot.document.credits.models["gpt-5.6-sol"]?.input, 100)
            XCTAssertNotNil(snapshot.document.api.rate("gpt-5.5"))
            XCTAssertNotNil(snapshot.document.credits.rate("gpt-5.5"))
        }
    }

    func testFallbackIsDistinctFromValidCustomDifferencesInJSON() throws {
        let snapshot = PricingCatalog.snapshot(PricingCatalog.builtin.document, source: "builtin",
                                              path: "/missing/pricing.json", error: "Missing custom file")
        let report = PricingHealth.report(snapshot)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        XCTAssertEqual(json["configurationStatus"] as? String, "fallback")
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        let api = try XCTUnwrap(json["api"] as? [String: Any])
        XCTAssertEqual(api["coverageReviewRecommended"] as? Bool, false)
        XCTAssertEqual(report.active.configurationError, "Missing custom file")
    }
}
