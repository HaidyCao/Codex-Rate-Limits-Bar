import Foundation

// Token-based purchased-credit rate card, verified 2026-09-11.
// https://help.openai.com/en/articles/11481834
// https://learn.chatgpt.com/docs/agent-configuration/speed
// https://help.openai.com/en/articles/20001415 (Astra long-context exception)
enum CodexCreditEstimator {
    private struct Rate: Sendable {
        let input: Double
        let cached: Double
        let output: Double
        var longContext = false
        var fastMultiplier: Double? = nil
    }

    private static let rates: [String: Rate] = [
        "gpt-6-astra": Rate(input: 250, cached: 25, output: 1_250, fastMultiplier: 2.5),
        "gpt-5.6-sol": Rate(input: 100, cached: 10, output: 500, longContext: true, fastMultiplier: 2.5),
        "gpt-5.6-terra": Rate(input: 50, cached: 5, output: 300, longContext: true, fastMultiplier: 2.5),
        "gpt-5.6-luna": Rate(input: 5, cached: 0.5, output: 30, longContext: true, fastMultiplier: 2.5),
        "gpt-5.6-cyber": Rate(input: 312.5, cached: 31.25, output: 1_875),
        "gpt-5.5": Rate(input: 125, cached: 12.5, output: 750, longContext: true, fastMultiplier: 2.5),
        "gpt-5.4": Rate(input: 62.5, cached: 6.25, output: 375, longContext: true, fastMultiplier: 2),
        "gpt-5.4-mini": Rate(input: 18.75, cached: 1.875, output: 113),
        "gpt-5.3-codex": Rate(input: 43.75, cached: 4.375, output: 350),
        "gpt-5.2": Rate(input: 43.75, cached: 4.375, output: 350),
    ]

    static func signature(for model: String) -> String {
        guard let rate = rates[model] else { return "credits-v1-unpriced" }
        return "credits-v1/\(rate.input)/\(rate.cached)/\(rate.output)/\(rate.longContext)/\(rate.fastMultiplier ?? 0)"
    }

    static func estimate(usage: TokenUsage, model: String?, requestInputTokens: Int64?, serviceTier: String?) -> Double? {
        guard let model = TokenCostEstimator.canonicalModel(model), let rate = rates[model] else { return nil }
        let tier = serviceTier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let multiplier: Double
        switch tier {
        case nil, "standard", "default": multiplier = 1
        case "fast", "priority":
            guard let fast = rate.fastMultiplier else { return nil }
            multiplier = fast
        default: return nil
        }
        // Astra keeps standard context rates in Codex. Other published tiers
        // apply to the whole request, not the daily accumulated input count.
        let long = rate.longContext && (requestInputTokens ?? 0) > TokenCostEstimator.longContextInputThreshold
        // Local input_tokens includes cached reads and writes. Cache writes
        // have no charge in this Codex credit estimate; API equivalents retain
        // their own separate cache-write price.
        let input = Double(usage.uncachedInputTokens) * rate.input
            + Double(usage.cachedInputTokens) * rate.cached
        let output = Double(usage.outputTokens) * rate.output
        return (input * (long ? 2 : 1) + output * (long ? 1.5 : 1)) * multiplier / 1_000_000
    }
}

public enum CreditFormatter {
    public static func string(_ amount: Double?) -> String {
        guard let amount, amount.isFinite else { return "--" }
        if amount > 0 && amount < 0.01 { return "<0.01" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount)) ?? "--"
    }
}
