import XCTest
@testable import CodexRateLimitsCore

final class EstimateFormattingTests: XCTestCase {
    func testSummationRoundoffDoesNotChangeCentRoundingAcrossProcesses() {
        for (amount, credits, usd) in [(92.415, "92.42", "$92.42"), (1.005, "1", "$1.00"), (1.015, "1.02", "$1.02")] {
            for value in [amount.nextDown, amount, amount.nextUp, amount - 1e-12, amount + 1e-12] {
                XCTAssertEqual(CreditFormatter.string(value), credits, "\(value)")
                XCTAssertEqual(USDFormatter.string(value), usd, "\(value)")
            }
        }
    }

    func testDisplayPrecisionPreservesRealDifferencesSmallValuesAndLargeFiniteAmounts() {
        XCTAssertEqual(CreditFormatter.string(92.414999), "92.41")
        XCTAssertEqual(CreditFormatter.string(92.415001), "92.42")
        XCTAssertEqual(USDFormatter.string(92.414999), "$92.41")
        XCTAssertEqual(USDFormatter.string(92.415001), "$92.42")
        XCTAssertEqual(CreditFormatter.string(0), "0")
        XCTAssertEqual(USDFormatter.string(0), "$0.00")
        XCTAssertEqual(CreditFormatter.string(1e-12), "<0.01")
        XCTAssertEqual(USDFormatter.string(1e-12), "<$0.01")
        XCTAssertEqual(USDFormatter.string(1_234_567_890.12), "$1,234,567,890.12")
        XCTAssertNotEqual(USDFormatter.string(Double.greatestFiniteMagnitude), "--")
        XCTAssertNotEqual(CreditFormatter.string(Double.greatestFiniteMagnitude), "--")
        XCTAssertEqual(CreditFormatter.string(.infinity), "--")
        XCTAssertEqual(USDFormatter.string(.nan), "--")
    }
}
