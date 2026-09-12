import Foundation

struct TokenUsage: Codable, Equatable, Sendable {
    var inputTokens: Int64 = 0
    var cachedInputTokens: Int64 = 0
    var cacheWriteInputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var reasoningOutputTokens: Int64 = 0
    var totalTokens: Int64 = 0
    // Optional for compatibility with existing cached counters. A delta can
    // look balanced even though one of its cumulative endpoints was incomplete.
    var breakdownUnavailable: Bool? = nil

    var hasCompleteBreakdown: Bool {
        breakdownUnavailable != true && inputTokens >= 0 && outputTokens >= 0
            && totalTokens >= inputTokens && totalTokens - inputTokens == outputTokens
            && cachedInputTokens >= 0 && cachedInputTokens <= inputTokens
            && cacheWriteInputTokens >= 0 && cacheWriteInputTokens <= inputTokens - cachedInputTokens
            && reasoningOutputTokens >= 0 && reasoningOutputTokens <= outputTokens
    }

    var uncachedInputTokens: Int64 {
        max(0, max(0, inputTokens - cachedInputTokens) - cacheWriteInputTokens)
    }

    static func from(_ value: Any?) -> TokenUsage? {
        guard let object = value as? [String: Any] else { return nil }
        guard nonnegativeInteger(object["total_tokens"]) != nil else { return nil }
        for key in ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens", "reasoning_output_tokens"] {
            if let value = object[key], nonnegativeInteger(value) == nil { return nil }
        }
        return TokenUsage(
            inputTokens: parseInt64(object["input_tokens"]),
            cachedInputTokens: parseInt64(object["cached_input_tokens"]),
            cacheWriteInputTokens: parseInt64(object["cache_write_input_tokens"]),
            outputTokens: parseInt64(object["output_tokens"]),
            reasoningOutputTokens: parseInt64(object["reasoning_output_tokens"]),
            totalTokens: parseInt64(object["total_tokens"])
        )
    }

    static func nonnegativeInteger(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let result = Int64(number.stringValue) ?? Int64(exactly: number.doubleValue), result >= 0 else { return nil }
            return result
        }
        if let string = value as? String, let result = Int64(string), result >= 0 { return result }
        return nil
    }

    private static func parseInt64(_ rawValue: Any?) -> Int64 {
        nonnegativeInteger(rawValue) ?? 0
    }

    mutating func add(_ other: TokenUsage) {
        if !hasCompleteBreakdown || !other.hasCompleteBreakdown { breakdownUnavailable = true }
        inputTokens += other.inputTokens
        cachedInputTokens += other.cachedInputTokens
        cacheWriteInputTokens += other.cacheWriteInputTokens
        outputTokens += other.outputTokens
        reasoningOutputTokens += other.reasoningOutputTokens
        totalTokens += other.totalTokens
    }
}

public enum USDFormatter {
    public static func string(_ amount: Double?) -> String {
        guard let amount, amount.isFinite, amount >= 0 else { return "--" }
        if amount > 0, amount < 0.01 {
            return "<$0.01"
        }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount)).map { "$\($0)" }
            ?? String(format: "$%.2f", amount)
    }
}

enum TokenCostEstimator {
    static func canonicalModel(_ model: String?) -> String? { PricingCatalog.current.document.api.canonical(model) }
    static func pricingSignature(for model: String) -> String {
        let snapshot = PricingCatalog.current
        let api = canonicalModel(model).flatMap { snapshot.apiSignatures[$0] } ?? "unpriced"
        let credits = snapshot.document.credits.canonical(model).flatMap { snapshot.creditSignatures[$0] } ?? "unpriced"
        return "pricing-v3|\(api)|\(credits)"
    }
    static func needsRequestContext(_ model: String?) -> Bool {
        PricingCatalog.current.document.api.rate(model)?.needsContext == true
    }
    static func estimateUSD(usage: TokenUsage, model: String?, requestInputTokens: Int64? = nil) -> Double? {
        PricingCatalog.current.document.api.rate(model)?.estimate(usage, requestInput: requestInputTokens)
    }
}

struct TokenCostAccumulator: Codable {
    private struct Totals: Codable {
        var amount = 0.0
        var pricedTokens: Int64 = 0
        var unpricedTokens: Int64 = 0
        var assumedStandardTokens: Int64 = 0
        mutating func merge(_ other: Totals) {
            amount += other.amount
            pricedTokens += other.pricedTokens
            unpricedTokens += other.unpricedTokens
            assumedStandardTokens += other.assumedStandardTokens
        }
        var estimate: Double? { pricedTokens > 0 ? amount : nil }
    }
    private struct Missing: Codable {
        let kind: String
        let tier: String?
        let reason: String
        var tokens: Int64
    }
    private struct Bucket: Codable {
        var usage = TokenUsage()
        var pricingSignature: String?
        var api: Totals?
        var credits: Totals?
        var assumptions: UsageBillingAssumptions?
        var missing: [Missing]?
    }
    private var buckets: [String: Bucket] = [:]

    var hasNewlyPricedModels: Bool {
        buckets.contains { model, bucket in
            bucket.api == nil && TokenCostEstimator.canonicalModel(model) != nil
                && bucket.pricingSignature != TokenCostEstimator.pricingSignature(for: model)
        }
    }
    var requiresRepricing: Bool {
        buckets.contains { model, bucket in
            bucket.pricingSignature != TokenCostEstimator.pricingSignature(for: model)
                || bucket.assumptions == nil || bucket.api == nil || bucket.missing == nil
        }
    }

    mutating func add(usage: TokenUsage, model: String?, requestInputTokens: Int64?, serviceTier: String? = nil) {
        let raw = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = raw.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        let signature = TokenCostEstimator.pricingSignature(for: label)
        var bucket = buckets[label] ?? Bucket(pricingSignature: signature, api: Totals(), credits: Totals(),
                                              assumptions: UsageBillingAssumptions(), missing: [])
        bucket.usage.add(usage)
        bucket.assumptions?.totalTokens += usage.totalTokens
        if serviceTier == nil { bucket.assumptions?.missingServiceTierTokens += usage.totalTokens }
        if requestInputTokens == nil { bucket.assumptions?.missingRequestContextTokens += usage.totalTokens }
        if requestInputTokens == nil, TokenCostEstimator.needsRequestContext(label) {
            bucket.assumptions?.assumedAPITokens += usage.totalTokens
        }
        // A new event cannot upgrade stale cached requests to current prices.
        if bucket.pricingSignature == signature {
            func missing(_ kind: String, _ reason: String) {
                if let index = bucket.missing?.firstIndex(where: { $0.kind == kind && $0.tier == serviceTier && $0.reason == reason }) {
                    bucket.missing?[index].tokens += usage.totalTokens
                } else { bucket.missing?.append(Missing(kind: kind, tier: serviceTier, reason: reason, tokens: usage.totalTokens)) }
            }
            if let cost = TokenCostEstimator.estimateUSD(usage: usage, model: label, requestInputTokens: requestInputTokens) {
                bucket.api?.amount += cost
                bucket.api?.pricedTokens += usage.totalTokens
            } else {
                bucket.api?.unpricedTokens += usage.totalTokens
                missing("api", !usage.hasCompleteBreakdown ? "incompleteTokenBreakdown"
                    : TokenCostEstimator.canonicalModel(label) == nil ? "unknownModel" : "unsupportedContext")
            }
            if let value = CodexCreditEstimator.estimate(usage: usage, model: label,
                                                       requestInputTokens: requestInputTokens, serviceTier: serviceTier) {
                bucket.credits?.amount += value
                bucket.credits?.pricedTokens += usage.totalTokens
                if serviceTier == nil { bucket.credits?.assumedStandardTokens += usage.totalTokens }
                if serviceTier == nil || (requestInputTokens == nil && CodexCreditEstimator.needsRequestContext(label)) {
                    bucket.assumptions?.assumedCreditTokens += usage.totalTokens
                }
            } else {
                bucket.credits?.unpricedTokens += usage.totalTokens
                missing("credits", !usage.hasCompleteBreakdown ? "incompleteTokenBreakdown"
                    : CodexCreditEstimator.unpricedReason(model: label, requestInputTokens: requestInputTokens, serviceTier: serviceTier))
            }
        } else {
            bucket.pricingSignature = nil
            bucket.api = nil
            bucket.credits = nil
            bucket.missing = nil
        }
        buckets[label] = bucket
    }

    mutating func merge(_ other: TokenCostAccumulator) {
        for (model, otherBucket) in other.buckets {
            guard var bucket = buckets[model] else { buckets[model] = otherBucket; continue }
            bucket.usage.add(otherBucket.usage)
            if let assumptions = otherBucket.assumptions { bucket.assumptions?.merge(assumptions) }
            else { bucket.assumptions = nil }
            if bucket.pricingSignature == otherBucket.pricingSignature {
                if let api = otherBucket.api { bucket.api?.merge(api) } else { bucket.api = nil }
                if let credits = otherBucket.credits { bucket.credits?.merge(credits) } else { bucket.credits = nil }
                if let missing = otherBucket.missing {
                    for entry in missing {
                        if let index = bucket.missing?.firstIndex(where: { $0.kind == entry.kind && $0.tier == entry.tier && $0.reason == entry.reason }) {
                            bucket.missing?[index].tokens += entry.tokens
                        } else { bucket.missing?.append(entry) }
                    }
                } else { bucket.missing = nil }
            } else {
                bucket.pricingSignature = nil
                bucket.api = nil
                bucket.credits = nil
                bucket.missing = nil
            }
            buckets[model] = bucket
        }
    }

    func estimate() -> UsageCostEstimate {
        var totals = Totals()
        var models: [UsageModelCost] = []
        for (model, bucket) in buckets {
            let current = bucket.pricingSignature == TokenCostEstimator.pricingSignature(for: model) && bucket.missing != nil
            let value = (current ? bucket.api : nil) ?? Totals(unpricedTokens: bucket.usage.totalTokens)
            totals.merge(value)
            models.append(UsageModelCost(model: model, inputTokens: bucket.usage.inputTokens,
                cachedInputTokens: bucket.usage.cachedInputTokens, cacheWriteInputTokens: bucket.usage.cacheWriteInputTokens,
                outputTokens: bucket.usage.outputTokens, totalTokens: bucket.usage.totalTokens, estimatedCostUSD: value.estimate,
                unpricedTokens: value.unpricedTokens, canonicalModel: TokenCostEstimator.canonicalModel(model), pricingSource: PricingCatalog.current.metadata.source))
        }
        let total = totals.pricedTokens + totals.unpricedTokens
        models.sort { $0.totalTokens == $1.totalTokens ? $0.model < $1.model : $0.totalTokens > $1.totalTokens }
        return UsageCostEstimate(estimatedCostUSD: total == 0 ? 0 : totals.estimate,
            coveragePercent: total > 0 ? Double(totals.pricedTokens) / Double(total) * 100 : 100,
            pricedTokens: totals.pricedTokens, unpricedTokens: totals.unpricedTokens, models: models)
    }

    func billingAssumptions() -> UsageBillingAssumptions {
        buckets.values.reduce(into: UsageBillingAssumptions()) { result, bucket in
            result.merge(bucket.assumptions ?? UsageBillingAssumptions(
                totalTokens: bucket.usage.totalTokens, missingServiceTierTokens: bucket.usage.totalTokens,
                missingRequestContextTokens: bucket.usage.totalTokens,
                assumedAPITokens: bucket.usage.totalTokens, assumedCreditTokens: bucket.usage.totalTokens))
        }
    }

    func creditEstimate() -> UsageCreditEstimate {
        var totals = Totals()
        var models: [UsageModelCredits] = []
        for (model, bucket) in buckets {
            let current = bucket.pricingSignature == TokenCostEstimator.pricingSignature(for: model) && bucket.missing != nil
            let value = (current ? bucket.credits : nil) ?? Totals(unpricedTokens: bucket.usage.totalTokens)
            totals.merge(value)
            models.append(UsageModelCredits(model: model, totalTokens: bucket.usage.totalTokens,
                estimatedCredits: value.estimate, unpricedTokens: value.unpricedTokens,
                canonicalModel: PricingCatalog.current.document.credits.canonical(model), pricingSource: PricingCatalog.current.metadata.source))
        }
        let total = totals.pricedTokens + totals.unpricedTokens
        models.sort { $0.totalTokens == $1.totalTokens ? $0.model < $1.model : $0.totalTokens > $1.totalTokens }
        return UsageCreditEstimate(estimatedCredits: total == 0 ? 0 : totals.estimate,
            coveragePercent: total > 0 ? Double(totals.pricedTokens) / Double(total) * 100 : 100,
            pricedTokens: totals.pricedTokens, unpricedTokens: totals.unpricedTokens,
            assumedStandardTokens: totals.assumedStandardTokens, models: models)
    }

    func unpricedUsage() -> [UnpricedUsage] {
        let total = buckets.values.reduce(Int64(0)) { $0 + $1.usage.totalTokens }
        guard total > 0 else { return [] }
        return buckets.flatMap { model, bucket -> [UnpricedUsage] in
            let current = bucket.pricingSignature == TokenCostEstimator.pricingSignature(for: model) && bucket.missing != nil
            let entries = ["api", "credits"].flatMap { kind -> [Missing] in
                let totals = kind == "api" ? bucket.api : bucket.credits
                return current && totals != nil ? bucket.missing!.filter { $0.kind == kind }
                    : [Missing(kind: kind, tier: nil, reason: "stalePricing", tokens: bucket.usage.totalTokens)]
            }
            return entries.filter { $0.tokens > 0 }.map {
                UnpricedUsage(kind: $0.kind, model: model, serviceTier: $0.tier, reason: $0.reason,
                              totalTokens: $0.tokens, percent: Double($0.tokens) / Double(total) * 100)
            }
        }.sorted { lhs, rhs in
            if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
            return [lhs.kind, lhs.model, lhs.serviceTier ?? "", lhs.reason].lexicographicallyPrecedes([rhs.kind, rhs.model, rhs.serviceTier ?? "", rhs.reason])
        }
    }
}
