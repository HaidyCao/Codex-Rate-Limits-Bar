import Foundation

enum CodexCreditEstimator {
    static func needsRequestContext(_ model: String?) -> Bool {
        PricingCatalog.current.document.credits.rate(model)?.needsContext == true
    }
    static func estimate(usage: TokenUsage, model: String?, requestInputTokens: Int64?, serviceTier: String?) -> Double? {
        guard let rate = PricingCatalog.current.document.credits.rate(model),
              let multiplier = rate.serviceTiers?[serviceTier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "standard"] else { return nil }
        return rate.estimate(usage, requestInput: requestInputTokens, multiplier: multiplier)
    }
    static func unpricedReason(model: String?, requestInputTokens: Int64?, serviceTier: String?) -> String {
        guard let rate = PricingCatalog.current.document.credits.rate(model) else { return "unknownModel" }
        let tier = serviceTier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "standard"
        if rate.serviceTiers?[tier] == nil { return "unknownServiceTier" }
        return "unsupportedContext"
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
