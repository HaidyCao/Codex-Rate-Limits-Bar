import Foundation
import XCTest
@testable import CodexRateLimitsCore

final class TokenAmountFormatterTests: XCTestCase {
    func testUsesLocalizedCJKUnits() {
        XCTAssertEqual(
            TokenAmountFormatter.compact(
                12_345,
                locale: Locale(identifier: "zh_CN"),
                preferredLanguages: ["zh-Hans-CN"]
            ),
            "1.23万"
        )
        XCTAssertEqual(
            TokenAmountFormatter.compact(
                12_345,
                locale: Locale(identifier: "zh_TW"),
                preferredLanguages: ["zh-Hant-TW"]
            ),
            "1.23萬"
        )
        XCTAssertEqual(
            TokenAmountFormatter.compact(
                12_345,
                locale: Locale(identifier: "ja_JP"),
                preferredLanguages: ["ja-JP"]
            ),
            "1.23万"
        )
        XCTAssertEqual(
            TokenAmountFormatter.compact(
                12_345,
                locale: Locale(identifier: "ko_KR"),
                preferredLanguages: ["ko-KR"]
            ),
            "1.23만"
        )
    }

    func testUsesWesternUnitsOutsideCJKLocales() {
        let locale = Locale(identifier: "en_US")
        let languages = ["en-US"]

        XCTAssertEqual(TokenAmountFormatter.compact(999, locale: locale, preferredLanguages: languages), "999")
        XCTAssertEqual(TokenAmountFormatter.compact(12_345, locale: locale, preferredLanguages: languages), "12.35K")
        XCTAssertEqual(TokenAmountFormatter.compact(81_464_198, locale: locale, preferredLanguages: languages), "81.46M")
        XCTAssertEqual(TokenAmountFormatter.compact(1_234_567_890, locale: locale, preferredLanguages: languages), "1.23B")
        XCTAssertEqual(TokenAmountFormatter.compact(1_234_567_890_123, locale: locale, preferredLanguages: languages), "1.23T")
    }

    func testCJKThresholdSwitchesFromTenThousandToHundredMillion() {
        let locale = Locale(identifier: "zh_CN")
        let languages = ["zh-Hans-CN"]

        XCTAssertEqual(TokenAmountFormatter.compact(9_999, locale: locale, preferredLanguages: languages), "9999")
        XCTAssertEqual(TokenAmountFormatter.compact(81_464_198, locale: locale, preferredLanguages: languages), "8,146.42万")
        XCTAssertEqual(TokenAmountFormatter.compact(123_456_789, locale: locale, preferredLanguages: languages), "1.23亿")
    }

    func testMaximumFractionDigitsRemainsCallerControlled() {
        XCTAssertEqual(
            TokenAmountFormatter.compact(
                12_345,
                maximumFractionDigits: 1,
                locale: Locale(identifier: "en_US"),
                preferredLanguages: ["en-US"]
            ),
            "12.3K"
        )
    }
}
