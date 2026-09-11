import Foundation

public struct WeeklyQuotaValuation: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case collecting, ready, paused, unstable }
    public enum Confidence: String, Codable, Sendable { case low, medium, high }
    public let status: Status
    public let confidence: Confidence
    public let reason: String?
    public let estimatedUSD: Double?
    public let lowerUSD: Double?
    public let upperUSD: Double?
    public let sampleCount: Int
    public let effectiveIntervalCount: Int
    public let rejectedIntervalCount: Int
    public let observationSpanSeconds: Double
    public let effectiveUsedPercent: Int
    public let sampleStartIso: String?
    public let sampleEndIso: String?
    public let lastQuotaSampleAtIso: String?
    public let creditAssumptionsPresent: Bool
    public let method: String
}

struct WeeklyCostBucket: Codable, Sendable {
    var costUSD = 0.0
    var unpricedTokens: Int64 = 0
    var assumedAPITokens: Int64 = 0
    var uncertainCreditTokens: Int64 = 0

    mutating func add(usage: TokenUsage, model: String?, requestInput: Int64?, tier: String?) {
        if let value = TokenCostEstimator.estimateUSD(usage: usage, model: model, requestInputTokens: requestInput) {
            costUSD += value
        } else { unpricedTokens += usage.totalTokens }
        if requestInput == nil, TokenCostEstimator.needsRequestContext(model) { assumedAPITokens += usage.totalTokens }
        if tier == nil || (requestInput == nil && CodexCreditEstimator.needsRequestContext(model))
            || CodexCreditEstimator.estimate(usage: usage, model: model, requestInputTokens: requestInput, serviceTier: tier) == nil {
            uncertainCreditTokens += usage.totalTokens
        }
    }

    mutating func merge(_ other: WeeklyCostBucket) {
        costUSD += other.costUSD
        unpricedTokens += other.unpricedTokens
        assumedAPITokens += other.assumedAPITokens
        uncertainCreditTokens += other.uncertainCreditTokens
    }
}

struct WeeklyQuotaSample: Codable, Equatable {
    let timestamp: Date
    let usedPercent: Int
}

struct WeeklyQuotaHistory: Codable {
    var samples: [WeeklyQuotaSample] = []
    var restartReason: String?

    mutating func observe(usedPercent: Int, at timestamp: Date, now: Date) {
        guard (0...100).contains(usedPercent), timestamp <= now.addingTimeInterval(5),
              now.timeIntervalSince(timestamp) <= WeeklyQuotaEstimator.freshness else { return }
        if let last = samples.last {
            guard timestamp > last.timestamp else { return }
            if timestamp.timeIntervalSince(last.timestamp) > WeeklyQuotaEstimator.maximumGap {
                samples = []
                restartReason = "samplingGap"
            } else if usedPercent < last.usedPercent {
                samples = []
                restartReason = "quotaRegression"
            } else if timestamp.timeIntervalSince(last.timestamp) < 60, usedPercent == last.usedPercent { return }
        }
        samples.append(WeeklyQuotaSample(timestamp: timestamp, usedPercent: usedPercent))
        samples.removeAll { $0.timestamp < now.addingTimeInterval(-WeeklyQuotaEstimator.historyDuration) }
        if samples.count > 1500 { samples.removeFirst(samples.count - 1500) }
    }
}

enum WeeklyQuotaEstimator {
    static let historyDuration: TimeInterval = 24 * 60 * 60
    static let alignmentAllowance: TimeInterval = 120
    static let bucketDuration: TimeInterval = 60
    static let freshness: TimeInterval = 5 * 60
    static let maximumGap: TimeInterval = 10 * 60
    static let minimumInterval: TimeInterval = 30 * 60
    static let minimumSignal = 5
    static let minimumIntervals = 3

    static func minute(_ timestamp: Date) -> Int { Int(floor(timestamp.timeIntervalSince1970 / bucketDuration)) }

    private struct Interval {
        let start: Date
        let end: Date
        let delta: Int
        let lower: Double
        let upper: Double
        let creditAssumptions: Bool
        let center: Double
    }

    static func evaluate(history: WeeklyQuotaHistory, buckets: [Int: WeeklyCostBucket],
                         coverageStart: Date, quotaSampleAt: Date?, scanIncomplete: Bool, now: Date) -> WeeklyQuotaValuation {
        let formatter = ISO8601DateFormatter()
        let samples = history.samples.filter {
            $0.timestamp >= max(coverageStart.addingTimeInterval(alignmentAllowance + bucketDuration), now.addingTimeInterval(-historyDuration))
                && $0.timestamp <= now.addingTimeInterval(5)
        }
        var accepted: [Interval] = []
        var rejected = 0
        var pendingCreditAssumptions = false
        func result(_ status: WeeklyQuotaValuation.Status, _ reason: String?,
                    confidence: WeeklyQuotaValuation.Confidence = .low, estimate: Double? = nil,
                    lower: Double? = nil, upper: Double? = nil) -> WeeklyQuotaValuation {
            let start = accepted.first?.start ?? samples.first?.timestamp
            let end = accepted.last?.end ?? samples.last?.timestamp
            return WeeklyQuotaValuation(status: status, confidence: confidence, reason: reason,
                estimatedUSD: estimate, lowerUSD: lower, upperUSD: upper, sampleCount: samples.count,
                effectiveIntervalCount: accepted.count, rejectedIntervalCount: rejected,
                observationSpanSeconds: start.flatMap { s in end.map { max(0, $0.timeIntervalSince(s)) } } ?? 0,
                effectiveUsedPercent: accepted.reduce(0) { $0 + $1.delta }, sampleStartIso: start.map(formatter.string),
                sampleEndIso: end.map(formatter.string), lastQuotaSampleAtIso: history.samples.last.map { formatter.string(from: $0.timestamp) },
                creditAssumptionsPresent: pendingCreditAssumptions || accepted.contains { $0.creditAssumptions }, method: "local-api-intervals-v1")
        }
        if scanIncomplete { return result(.paused, "incompleteScan") }
        guard let quotaSampleAt else { return result(.paused, "quotaTimestampUnavailable") }
        guard quotaSampleAt <= now.addingTimeInterval(5), now.timeIntervalSince(quotaSampleAt) <= freshness else {
            return result(.paused, "staleQuota")
        }
        if let last = history.samples.last, quotaSampleAt < last.timestamp { return result(.paused, "supersededSample") }
        if history.samples.last?.usedPercent == 100 { return result(.paused, "quotaExhausted") }
        guard let first = samples.first else { return result(.collecting, "aligningSamples") }

        // Model a two-minute lag allowance at each official read; this is a
        // local assumption, not a server guarantee. Whole minute bins
        // strictly inside the interval form the lower bound; intersecting bins
        // form the upper bound. The range also allows ±1 percentage point for
        // the difference of two rounded/truncated official percentages.
        func bounds(from start: Date, to end: Date) -> (lower: Double, upper: Double, credit: Bool, reason: String?) {
            var lower = 0.0, upper = 0.0, credit = false
            var unknown = false, assumedAPI = false
            for (minute, bucket) in buckets {
                let begin = Date(timeIntervalSince1970: Double(minute) * bucketDuration)
                let finish = begin.addingTimeInterval(bucketDuration)
                guard finish > start.addingTimeInterval(-alignmentAllowance), begin < end else { continue }
                upper += bucket.costUSD
                if begin >= start, finish <= end.addingTimeInterval(-alignmentAllowance) { lower += bucket.costUSD }
                unknown = unknown || bucket.unpricedTokens > 0
                assumedAPI = assumedAPI || bucket.assumedAPITokens > 0
                credit = credit || bucket.uncertainCreditTokens > 0
            }
            return (lower, upper, credit, unknown ? "unpricedUsage" : assumedAPI ? "billingAssumptions" : nil)
        }

        var anchor = first
        var candidates: [Interval] = []
        var lastFailure: String?
        for sample in samples.dropFirst() {
            let delta = sample.usedPercent - anchor.usedPercent
            guard sample.timestamp.timeIntervalSince(anchor.timestamp) >= minimumInterval, delta >= minimumSignal else { continue }
            let value = bounds(from: anchor.timestamp, to: sample.timestamp)
            if let reason = value.reason { rejected += 1; lastFailure = reason }
            else if value.upper <= 0 { rejected += 1; lastFailure = "noLocalUsage" }
            else if value.lower <= 0 { rejected += 1; lastFailure = "alignmentUncertain" }
            else {
                candidates.append(Interval(start: anchor.timestamp, end: sample.timestamp, delta: delta,
                    lower: value.lower * 100 / Double(delta + 1), upper: value.upper * 100 / Double(delta - 1),
                    creditAssumptions: value.credit, center: (value.lower + value.upper) * 50 / Double(delta)))
                lastFailure = nil
            }
            anchor = sample
        }
        if let latest = samples.last, latest.timestamp > anchor.timestamp {
            let pending = bounds(from: anchor.timestamp, to: latest.timestamp)
            if let reason = pending.reason { lastFailure = reason }
            pendingCreditAssumptions = pending.credit
        }
        accepted = candidates
        if let lastFailure { return result(.paused, lastFailure) }

        // Robustly exclude isolated changes in the cost/quota relation. A new
        // outlying interval pauses the estimate until subsequent data agrees.
        if candidates.count >= minimumIntervals {
            let center = median(candidates.map(\.center))
            accepted = candidates.filter { $0.center >= center / 3 && $0.center <= center * 3 }
            rejected += candidates.count - accepted.count
            if accepted.last?.end != candidates.last?.end { return result(.unstable, "unstableSamples") }
        }
        guard accepted.count >= minimumIntervals else {
            let span = samples.last?.timestamp.timeIntervalSince(first.timestamp) ?? 0
            let signal = (samples.last?.usedPercent ?? first.usedPercent) - first.usedPercent
            let reason = history.restartReason ?? (span < minimumInterval * Double(minimumIntervals) ? "insufficientDuration"
                : signal < minimumSignal * minimumIntervals ? "insufficientSignal" : "insufficientSamples")
            return result(.collecting, reason)
        }
        let center = median(accepted.map(\.center))
        let deviation = median(accepted.map { abs($0.center - center) }) / center
        let lower = accepted.map(\.lower).min()!
        let upper = accepted.map(\.upper).max()!
        let width = (upper - lower) / center
        guard center.isFinite, lower > 0, upper.isFinite, deviation <= 0.25, width <= 0.85 else {
            return result(.unstable, "unstableSamples")
        }
        let span = accepted.last!.end.timeIntervalSince(accepted.first!.start)
        let strong = accepted.count >= 6 && span >= 6 * 60 * 60 && accepted.reduce(0, { $0 + $1.delta }) >= 30
            && deviation <= 0.1 && width <= 0.4 && rejected == 0 && !pendingCreditAssumptions && !accepted.contains { $0.creditAssumptions }
        return result(.ready, nil, confidence: strong ? .high : .medium, estimate: center, lower: lower, upper: upper)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
