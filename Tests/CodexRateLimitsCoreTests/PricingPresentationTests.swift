import XCTest
@testable import CodexRateLimitsCore

final class PricingPresentationTests: XCTestCase {
    private func entry(_ kind: String, _ reason: String, tokens: Int64 = 100, tier: String? = nil) -> UnpricedUsage {
        UnpricedUsage(kind: kind, model: "Raw-Model", serviceTier: tier, reason: reason, totalTokens: tokens, percent: 25)
    }

    func testSummaryUsesLargestAffectedEntryAndDoesNotCountAPICreditsTwice() throws {
        let values = [entry("api", "unknownModel"), entry("credits", "unknownModel"),
                      entry("credits", "unverifiedCacheWrite", tokens: 200),
                      entry("credits", "incompleteTokenBreakdown", tokens: 0)]
        let summary = try XCTUnwrap(AppText.unpricedSummary(values))
        XCTAssertTrue(summary.contains(AppText.unpricedReason("unverifiedCacheWrite")))
        XCTAssertTrue(summary.hasSuffix(" · +1"))
        XCTAssertEqual(summary, AppText.unpricedSummary(values.reversed()))
        XCTAssertNil(AppText.unpricedSummary([]))
        XCTAssertNil(AppText.unpricedSummary([entry("api", "unknownModel", tokens: 0)]))
    }

    func testDetailsKeepModelModeTokensAndIndependentCoverage() throws {
        let details = try XCTUnwrap(AppText.unpricedUsageDetails([
            entry("api", "unknownModel"), entry("credits", "unknownServiceTier", tier: "Odd-Mode")]))
        XCTAssertTrue(details.contains("Standard API"))
        XCTAssertTrue(details.contains("Raw-Model"))
        XCTAssertTrue(details.contains("Odd-Mode"))
        XCTAssertEqual(details.components(separatedBy: "100 tokens (25.00%)").count, 3)
        XCTAssertFalse(details.contains("50.00%"), "Two valuations must not be added together")
        let missing = try XCTUnwrap(AppText.unpricedUsageDetails([entry("credits", "stalePricing")]))
        let recorded = try XCTUnwrap(AppText.unpricedUsageDetails([entry("credits", "stalePricing", tier: "standard")]))
        XCTAssertNotEqual(missing, recorded, "An absent mode must not silently be labeled Standard")
    }

    func testUnknownFutureReasonIsNotMisrepresentedAsRepricing() {
        let future = AppText.unpricedReason("future-policy-code")
        XCTAssertTrue(future.contains("future-policy-code"))
        XCTAssertFalse(future.contains(AppText.unpricedReason("stalePricing")))
        let reasons = ["unknownModel", "unknownServiceTier", "unsupportedContext", "unverifiedCacheWrite",
                       "incompleteTokenBreakdown", "stalePricing"]
        XCTAssertEqual(Set(reasons.map(AppText.unpricedReason)).count, reasons.count)
    }

    func testOldDisplayDecodesAndNewFailureSnapshotExplainsValuationScope() throws {
        let old = try JSONDecoder().decode(LocalUsageDisplay.self, from: Data(#"{"estimatedCostLabel":"legacy"}"#.utf8))
        XCTAssertEqual(old.estimatedCostLabel, "legacy")
        XCTAssertNil(old.unpricedSummaryLabel)
        XCTAssertNil(old.pricingBasisDetails)
        let failed = LocalUsageFormatting.emptyLocalUsageSnapshot(RuntimeError("fixture read failure"))
        XCTAssertNil(failed.todayCost)
        XCTAssertNil(failed.unpricedUsage)
        let basis = try XCTUnwrap(failed.display?.pricingBasisDetails)
        for term in ["Standard API", "API-key", "Enterprise USD", "Enterprise", "Work", "credits"] {
            XCTAssertTrue(basis.contains(term), term)
        }
        let decoded = try JSONDecoder().decode(LocalUsageSnapshot.self, from: JSONEncoder().encode(failed))
        XCTAssertEqual(decoded.display?.pricingBasisDetails, basis)
        XCTAssertEqual(decoded.error, "fixture read failure")
    }
}
