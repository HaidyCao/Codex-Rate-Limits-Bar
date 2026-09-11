import Foundation
import XCTest
@testable import CodexRateLimitsCore

final class WeeklyQuotaEstimatorTests: XCTestCase {
    private let start = ISO8601DateFormatter().date(from: "2026-09-11T00:00:00Z")!
    private func at(_ minute: Int) -> Date { start.addingTimeInterval(Double(minute) * 60) }

    private func fixture(minutes: Int = 90, hourlySteps: Bool = false) -> (WeeklyQuotaHistory, [Int: WeeklyCostBucket]) {
        var history = WeeklyQuotaHistory()
        for minute in stride(from: 0, through: minutes, by: 5) {
            let used = 10 + (hourlySteps ? minute / 60 * 10 : minute / 6)
            history.observe(usedPercent: used, at: at(minute), now: at(minute))
        }
        let buckets = Dictionary(uniqueKeysWithValues: (-3..<minutes).map { minute in
            (WeeklyQuotaEstimator.minute(at(minute)), WeeklyCostBucket(costUSD: 1.0 / 6))
        })
        return (history, buckets)
    }

    private func evaluate(_ history: WeeklyQuotaHistory, _ buckets: [Int: WeeklyCostBucket], now: Date? = nil,
                          incomplete: Bool = false, sampleAt: Date? = nil) -> WeeklyQuotaValuation {
        WeeklyQuotaEstimator.evaluate(history: history, buckets: buckets, coverageStart: at(-60),
            quotaSampleAt: sampleAt ?? history.samples.last?.timestamp, scanIncomplete: incomplete,
            now: now ?? history.samples.last?.timestamp ?? start)
    }

    func testShortSamplesAndSmallSignalsNeverProduceAValue() {
        let (history, buckets) = fixture(minutes: 15)
        let short = evaluate(history, buckets)
        XCTAssertEqual(short.status, .collecting)
        XCTAssertNil(short.estimatedUSD)
        XCTAssertEqual(short.confidence, .low)
        var flat = WeeklyQuotaHistory()
        for minute in stride(from: 0, through: 120, by: 5) {
            flat.observe(usedPercent: 10 + minute / 60, at: at(minute), now: at(minute))
        }
        XCTAssertEqual(evaluate(flat, buckets).reason, "insufficientSignal")
    }

    func testIndependentStableIntervalsProduceABoundedEstimate() throws {
        let (history, buckets) = fixture()
        let result = evaluate(history, buckets)
        XCTAssertEqual(result.status, .ready)
        XCTAssertEqual(result.confidence, .medium)
        XCTAssertEqual(result.effectiveIntervalCount, 3)
        XCTAssertEqual(result.observationSpanSeconds, 90 * 60)
        XCTAssertEqual(result.effectiveUsedPercent, 15)
        XCTAssertEqual(try XCTUnwrap(result.estimatedUSD), 100, accuracy: 0.00001)
        XCTAssertLessThan(try XCTUnwrap(result.lowerUSD), 100)
        XCTAssertGreaterThan(try XCTUnwrap(result.upperUSD), 100)
    }

    func testLongStableEvidenceCanBecomeHighConfidenceAndCreditAssumptionsCapIt() {
        let (history, original) = fixture(minutes: 360, hourlySteps: true)
        XCTAssertEqual(evaluate(history, original).confidence, .high)
        var assumed = original
        assumed[WeeklyQuotaEstimator.minute(at(350))]?.uncertainCreditTokens = 100
        let result = evaluate(history, assumed)
        XCTAssertEqual(result.status, .ready)
        XCTAssertEqual(result.confidence, .medium)
        XCTAssertTrue(result.creditAssumptionsPresent)
    }

    func testRepeatedOldQuotaReadsDoNotCreateSamplesAndEventuallyExpire() {
        var (history, buckets) = fixture()
        let originalCount = history.samples.count
        for _ in 0..<100 { history.observe(usedPercent: 25, at: at(90), now: at(92)) }
        XCTAssertEqual(history.samples.count, originalCount)
        XCTAssertEqual(evaluate(history, buckets, now: at(92)).effectiveIntervalCount, 3)
        XCTAssertEqual(evaluate(history, buckets, now: at(96)).reason, "staleQuota")
        XCTAssertNil(evaluate(history, buckets, now: at(96)).estimatedUSD)
        XCTAssertEqual(evaluate(history, buckets, sampleAt: at(85)).reason, "supersededSample")
    }

    func testGapsRegressionsAndOutOfOrderResponsesDoNotJoinDifferentSegments() {
        var (history, buckets) = fixture()
        history.observe(usedPercent: 5, at: at(80), now: at(90))
        XCTAssertEqual(history.samples.last?.usedPercent, 25)
        history.observe(usedPercent: 30, at: at(110), now: at(110))
        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(evaluate(history, buckets).reason, "samplingGap")
        history.observe(usedPercent: 20, at: at(115), now: at(115))
        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(evaluate(history, buckets).reason, "quotaRegression")
    }

    func testUnknownPricesAndAPIAssumptionsPauseEvenWithTinyTokenShare() {
        let (history, original) = fixture()
        var buckets = original
        buckets[WeeklyQuotaEstimator.minute(at(89))]?.unpricedTokens = 1
        XCTAssertEqual(evaluate(history, buckets).reason, "unpricedUsage")
        XCTAssertNil(evaluate(history, buckets).estimatedUSD)
        buckets = original
        buckets[WeeklyQuotaEstimator.minute(at(89))]?.assumedAPITokens = 1
        XCTAssertEqual(evaluate(history, buckets).reason, "billingAssumptions")
        XCTAssertEqual(evaluate(history, original, incomplete: true).reason, "incompleteScan")
        XCTAssertEqual(evaluate(history, original).status, .ready)
    }

    func testBadIntervalsAreExcludedAndCleanEvidenceCanRecover() {
        let (history, original) = fixture(minutes: 150)
        var buckets = original
        buckets[WeeklyQuotaEstimator.minute(at(15))]?.unpricedTokens = 1
        let result = evaluate(history, buckets)
        XCTAssertEqual(result.status, .ready)
        XCTAssertEqual(result.effectiveIntervalCount, 4)
        XCTAssertEqual(result.rejectedIntervalCount, 1)
        XCTAssertEqual(result.confidence, .medium)
    }

    func testAbruptChangesAndUnmatchedQuotaConsumptionAreNotConfidentValues() {
        let (history, original) = fixture()
        var buckets = original
        for minute in 60..<90 { buckets[WeeklyQuotaEstimator.minute(at(minute))]?.costUSD = 10 }
        let outlier = evaluate(history, buckets)
        XCTAssertEqual(outlier.status, .unstable)
        XCTAssertEqual(outlier.rejectedIntervalCount, 1)
        XCTAssertNil(outlier.estimatedUSD)
        XCTAssertEqual(evaluate(history, [:]).reason, "noLocalUsage")
    }

    func testQuotaStepsAccumulateCostAndFutureUsageDoesNotChangeEarlierIntervals() throws {
        let (history, original) = fixture(minutes: 180, hourlySteps: true)
        var buckets = original
        let before = evaluate(history, buckets)
        XCTAssertEqual(before.status, .ready)
        XCTAssertEqual(try XCTUnwrap(before.estimatedUSD), 100, accuracy: 0.00001)
        for minute in 180..<190 { buckets[WeeklyQuotaEstimator.minute(at(minute))] = WeeklyCostBucket(costUSD: 10_000) }
        let after = evaluate(history, buckets)
        XCTAssertEqual(after.estimatedUSD, before.estimatedUSD)
        XCTAssertEqual(after.upperUSD, before.upperUSD)
    }

    func testConfidenceDoesNotPretendThatLocalCoverageMeasuresOtherDevices() {
        let (history, buckets) = fixture()
        let unknownTime = WeeklyQuotaEstimator.evaluate(history: history, buckets: buckets, coverageStart: at(-60),
            quotaSampleAt: nil, scanIncomplete: false, now: at(90))
        XCTAssertEqual(unknownTime.reason, "quotaTimestampUnavailable")
        var exhausted = history
        exhausted.observe(usedPercent: 100, at: at(95), now: at(95))
        XCTAssertEqual(evaluate(exhausted, buckets).reason, "quotaExhausted")
    }

    func testMinuteCostRepricingRecalculatesTheRangeWithoutDuplicatingQuotaSamples() throws {
        let (history, original) = fixture()
        let before = evaluate(history, original)
        let repriced = original.mapValues { WeeklyCostBucket(costUSD: $0.costUSD * 2) }
        let after = evaluate(history, repriced)
        XCTAssertEqual(try XCTUnwrap(after.estimatedUSD), try XCTUnwrap(before.estimatedUSD) * 2, accuracy: 0.00001)
        XCTAssertEqual(after.sampleCount, before.sampleCount)
        XCTAssertEqual(after.sampleStartIso, before.sampleStartIso)
    }

    func testDisplayedRangeRoundsOutwardWithoutFalseCentPrecision() {
        XCTAssertEqual(AppText.weeklyValueRange(lower: 78.123, upper: 133.456), "$70–$140")
        XCTAssertEqual(AppText.weeklyValueRange(lower: 1.866, upper: 3.2), "$1.8–$3.2")
        XCTAssertEqual(AppText.weeklyValueRange(lower: 0.0001, upper: 0.0003), "<$0.01")
    }
}
