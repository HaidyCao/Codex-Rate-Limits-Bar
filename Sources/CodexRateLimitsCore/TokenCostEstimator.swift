import Foundation

struct TokenUsage: Codable, Equatable, Sendable {
    var inputTokens: Int64 = 0
    var cachedInputTokens: Int64 = 0
    var cacheWriteInputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var reasoningOutputTokens: Int64 = 0
    var totalTokens: Int64 = 0

    var uncachedInputTokens: Int64 {
        max(0, inputTokens - cachedInputTokens - cacheWriteInputTokens)
    }

    static func from(_ value: Any?) -> TokenUsage? {
        guard let object = value as? [String: Any] else { return nil }
        return TokenUsage(
            inputTokens: parseInt64(object["input_tokens"]),
            cachedInputTokens: parseInt64(object["cached_input_tokens"]),
            cacheWriteInputTokens: parseInt64(object["cache_write_input_tokens"]),
            outputTokens: parseInt64(object["output_tokens"]),
            reasoningOutputTokens: parseInt64(object["reasoning_output_tokens"]),
            totalTokens: parseInt64(object["total_tokens"])
        )
    }

    private static func parseInt64(_ rawValue: Any?) -> Int64 {
        guard let rawValue, !(rawValue is NSNull) else { return 0 }
        if let rawValue = rawValue as? Int64 { return rawValue }
        if let rawValue = rawValue as? Int { return Int64(rawValue) }
        if let rawValue = rawValue as? Double { return Int64(rawValue) }
        if let rawValue = rawValue as? NSNumber { return rawValue.int64Value }
        if let rawValue = rawValue as? String { return Int64(rawValue) ?? 0 }
        return 0
    }

    mutating func add(_ other: TokenUsage) {
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
    // Standard API-equivalent prices checked on 2026-09-11, in USD per 1M tokens.
    // https://developers.openai.com/api/docs/pricing
    static let longContextInputThreshold: Int64 = 272_000

    private struct Price: Sendable {
        let input: Double
        let cachedInput: Double
        let cacheWriteInput: Double
        let output: Double
        let usesLongContextTier: Bool

        init(
            input: Double,
            cachedInput: Double,
            cacheWriteInput: Double? = nil,
            output: Double,
            usesLongContextTier: Bool = false
        ) {
            self.input = input
            self.cachedInput = cachedInput
            self.cacheWriteInput = cacheWriteInput ?? input
            self.output = output
            self.usesLongContextTier = usesLongContextTier
        }
    }

    private static let prices: [String: Price] = [
        "gpt-5.6-cyber": Price(input: 12.50, cachedInput: 1.25, cacheWriteInput: 15.625, output: 75.00, usesLongContextTier: true),
        "gpt-6-astra": Price(input: 10.00, cachedInput: 1.00, cacheWriteInput: 12.50, output: 50.00, usesLongContextTier: true),
        "gpt-5.6-sol": Price(input: 4.00, cachedInput: 0.40, cacheWriteInput: 5.00, output: 20.00, usesLongContextTier: true),
        "gpt-5.6-terra": Price(input: 2.00, cachedInput: 0.20, cacheWriteInput: 2.50, output: 12.00, usesLongContextTier: true),
        "gpt-5.6-luna": Price(input: 0.20, cachedInput: 0.02, cacheWriteInput: 0.25, output: 1.20, usesLongContextTier: true),
        "gpt-5.5": Price(input: 5.00, cachedInput: 0.50, cacheWriteInput: 6.25, output: 30.00, usesLongContextTier: true),
        "gpt-5.4": Price(input: 2.50, cachedInput: 0.25, cacheWriteInput: 3.125, output: 15.00, usesLongContextTier: true),
        "gpt-5.4-mini": Price(input: 0.75, cachedInput: 0.075, output: 4.50),
        "gpt-5.3-codex": Price(input: 1.75, cachedInput: 0.175, output: 14.00),
        "gpt-5.3-chat-latest": Price(input: 1.75, cachedInput: 0.175, output: 14.00),
        "gpt-5.2-codex": Price(input: 1.75, cachedInput: 0.175, output: 14.00),
        "gpt-5.2-chat-latest": Price(input: 1.75, cachedInput: 0.175, output: 14.00),
        "gpt-5.2": Price(input: 1.75, cachedInput: 0.175, output: 14.00),
        "gpt-5.1-codex-max": Price(input: 1.25, cachedInput: 0.125, output: 10.00),
        "gpt-5.1-codex-mini": Price(input: 0.25, cachedInput: 0.025, output: 2.00),
        "gpt-5.1-codex": Price(input: 1.25, cachedInput: 0.125, output: 10.00),
        "gpt-5-codex": Price(input: 1.25, cachedInput: 0.125, output: 10.00),
        "gpt-5": Price(input: 1.25, cachedInput: 0.125, output: 10.00),
    ]

    private static let aliases = [
        "gpt-5.6": "gpt-5.6-sol",
        "gpt-5.6-latest": "gpt-5.6-sol",
        "gpt-daybreak-blue-latest": "gpt-5.6-sol",
        "gpt-daybreak-red-latest": "gpt-5.6-cyber",
    ]

    static func canonicalModel(_ model: String?) -> String? {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !model.isEmpty else { return nil }
        if let alias = aliases[model] { return alias }
        if prices[model] != nil { return model }
        // Only dated snapshots may inherit a base price. Spark, Pro and future
        // variants are distinct models, even when their names share a prefix.
        guard let suffix = model.range(of: #"-[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression)
        else { return nil }
        let base = String(model[..<suffix.lowerBound])
        if base == "gpt-5.6" { return "gpt-5.6-sol" }
        return prices[base] != nil ? base : nil
    }

    // Persist the effective rules with each raw model bucket. A price or alias
    // change invalidates only affected files, without discarding weekly baselines.
    static func pricingSignature(for model: String) -> String {
        let canonical = canonicalModel(model) ?? model
        let api = prices[canonical].map {
            "\($0.input)/\($0.cachedInput)/\($0.cacheWriteInput)/\($0.output)/\($0.usesLongContextTier)"
        } ?? "unpriced"
        return "raw-model-v1|\(canonical)|\(api)|\(CodexCreditEstimator.signature(for: canonical))"
    }

    static func estimateUSD(
        usage: TokenUsage,
        model: String?,
        requestInputTokens: Int64? = nil
    ) -> Double? {
        guard let model = canonicalModel(model), let price = prices[model] else { return nil }
        let isLongContext = price.usesLongContextTier
            && requestInputTokens.map { $0 > longContextInputThreshold } == true
        let inputMultiplier = isLongContext ? 2.0 : 1.0
        let outputMultiplier = isLongContext ? 1.5 : 1.0
        let cost = Double(usage.uncachedInputTokens) * price.input * inputMultiplier
            + Double(usage.cachedInputTokens) * price.cachedInput * inputMultiplier
            + Double(usage.cacheWriteInputTokens) * price.cacheWriteInput * inputMultiplier
            + Double(usage.outputTokens) * price.output * outputMultiplier
        return cost / 1_000_000
    }
}

struct TokenCostAccumulator: Codable {
    private struct Bucket: Codable {
        var usage = TokenUsage()
        var estimatedCostUSD: Double?
        var pricingSignature: String?
        var credits: CreditTotals?
    }

    private struct CreditTotals: Codable {
        var amount = 0.0
        var pricedTokens: Int64 = 0
        var unpricedTokens: Int64 = 0
        var assumedStandardTokens: Int64 = 0

        mutating func merge(_ other: CreditTotals) {
            amount += other.amount
            pricedTokens += other.pricedTokens
            unpricedTokens += other.unpricedTokens
            assumedStandardTokens += other.assumedStandardTokens
        }
    }

    private var buckets: [String: Bucket] = [:]

    var hasNewlyPricedModels: Bool {
        buckets.contains { model, bucket in
            bucket.estimatedCostUSD == nil && TokenCostEstimator.canonicalModel(model) != nil
        }
    }

    var requiresRepricing: Bool {
        hasNewlyPricedModels || buckets.contains { model, bucket in
            bucket.pricingSignature != TokenCostEstimator.pricingSignature(for: model)
        }
    }

    mutating func add(usage: TokenUsage, model: String?, requestInputTokens: Int64?, serviceTier: String? = nil) {
        let raw = model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let label = raw.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        let signature = TokenCostEstimator.pricingSignature(for: label)
        let existing = buckets[label]
        var bucket = existing ?? Bucket(pricingSignature: signature, credits: CreditTotals())
        let eventCost = TokenCostEstimator.estimateUSD(usage: usage, model: label, requestInputTokens: requestInputTokens)
        let hadUnpricedUsage = existing != nil && bucket.estimatedCostUSD == nil
        bucket.usage.add(usage)
        if bucket.pricingSignature == signature {
            if let eventCost, !hadUnpricedUsage {
                bucket.estimatedCostUSD = (bucket.estimatedCostUSD ?? 0) + eventCost
            }
            if let value = CodexCreditEstimator.estimate(usage: usage, model: label,
                                                       requestInputTokens: requestInputTokens, serviceTier: serviceTier) {
                bucket.credits?.amount += value
                bucket.credits?.pricedTokens += usage.totalTokens
                if serviceTier == nil {
                    bucket.credits?.assumedStandardTokens += usage.totalTokens
                }
            } else {
                bucket.credits?.unpricedTokens += usage.totalTokens
            }
        }
        // Never upgrade stale history by appending one event. The scanner must
        // replay its requests to recover models, context sizes and service tiers.
        buckets[label] = bucket
    }

    mutating func merge(_ other: TokenCostAccumulator) {
        for (model, otherBucket) in other.buckets {
            guard var bucket = buckets[model] else {
                buckets[model] = otherBucket
                continue
            }
            bucket.usage.add(otherBucket.usage)
            if bucket.pricingSignature == otherBucket.pricingSignature {
                if let cost = bucket.estimatedCostUSD, let otherCost = otherBucket.estimatedCostUSD {
                    bucket.estimatedCostUSD = cost + otherCost
                } else {
                    bucket.estimatedCostUSD = nil
                }
                if let credits = otherBucket.credits { bucket.credits?.merge(credits) }
                else { bucket.credits = nil }
            } else {
                bucket.pricingSignature = nil
                bucket.estimatedCostUSD = nil
                bucket.credits = nil
            }
            buckets[model] = bucket
        }
    }

    func estimate() -> UsageCostEstimate {
        var knownCost = 0.0
        var pricedTokens: Int64 = 0
        var unpricedTokens: Int64 = 0
        var models: [UsageModelCost] = []
        for (model, bucket) in buckets {
            let cost = bucket.pricingSignature == TokenCostEstimator.pricingSignature(for: model)
                ? bucket.estimatedCostUSD : nil
            if let cost {
                knownCost += cost
                pricedTokens += bucket.usage.totalTokens
            } else {
                unpricedTokens += bucket.usage.totalTokens
            }
            models.append(UsageModelCost(
                model: model, inputTokens: bucket.usage.inputTokens,
                cachedInputTokens: bucket.usage.cachedInputTokens,
                cacheWriteInputTokens: bucket.usage.cacheWriteInputTokens,
                outputTokens: bucket.usage.outputTokens, totalTokens: bucket.usage.totalTokens,
                estimatedCostUSD: cost
            ))
        }
        let total = pricedTokens + unpricedTokens
        models.sort { $0.totalTokens == $1.totalTokens ? $0.model < $1.model : $0.totalTokens > $1.totalTokens }
        return UsageCostEstimate(
            estimatedCostUSD: pricedTokens > 0 || total == 0 ? knownCost : nil,
            coveragePercent: total > 0 ? Double(pricedTokens) / Double(total) * 100 : 100,
            pricedTokens: pricedTokens, unpricedTokens: unpricedTokens, models: models
        )
    }

    func creditEstimate() -> UsageCreditEstimate {
        var totals = CreditTotals()
        var models: [UsageModelCredits] = []
        for (model, bucket) in buckets {
            let credits = bucket.pricingSignature == TokenCostEstimator.pricingSignature(for: model)
                ? bucket.credits : nil
            let value = credits ?? CreditTotals(unpricedTokens: bucket.usage.totalTokens)
            totals.merge(value)
            models.append(UsageModelCredits(
                model: model, totalTokens: bucket.usage.totalTokens,
                estimatedCredits: value.pricedTokens > 0 ? value.amount : nil,
                unpricedTokens: value.unpricedTokens
            ))
        }
        let total = totals.pricedTokens + totals.unpricedTokens
        models.sort { $0.totalTokens == $1.totalTokens ? $0.model < $1.model : $0.totalTokens > $1.totalTokens }
        return UsageCreditEstimate(
            estimatedCredits: totals.pricedTokens > 0 || total == 0 ? totals.amount : nil,
            coveragePercent: total > 0 ? Double(totals.pricedTokens) / Double(total) * 100 : 100,
            pricedTokens: totals.pricedTokens, unpricedTokens: totals.unpricedTokens,
            assumedStandardTokens: totals.assumedStandardTokens, models: models
        )
    }
}
