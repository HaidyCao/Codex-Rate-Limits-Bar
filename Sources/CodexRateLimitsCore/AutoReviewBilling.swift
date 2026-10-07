import Foundation

enum AutoReviewBillingClass: String, Codable, Sendable {
    case regular, freeSafetyCheck, unverifiedSafetyCheck
}

/// Only the two source predicates are cached, never account IDs or credentials.
struct SessionBillingContext: Codable, Sendable {
    let guardian: Bool
    let openAI: Bool

    init(payload: [String: Any]) {
        let subagent = dictionaryValue(payload["source"]).flatMap { dictionaryValue($0["subagent"]) }
        guardian = stringValue(subagent?["other"]) == "guardian"
        openAI = stringValue(payload["model_provider"]) == "openai"
    }
}

enum AutoReviewBillingPolicy {
    static let model = "codex-auto-review"
    static let identifier = "chatgpt-auto-review-v1"
    static let source = "https://help.openai.com/en/articles/11481834-chatgpt-rate-card-business-enterpriseedu-credit-based-pricing"

    static func matches(_ name: String?) -> Bool {
        name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == model
    }

    static func classify(model: String?, context: SessionBillingContext?, payload: [String: Any]) -> AutoReviewBillingClass {
        guard matches(model), context?.guardian == true else { return .regular }
        guard context?.openAI == true, let limits = dictionaryValue(payload["rate_limits"]),
              stringValue(limits["limit_id"]) == "codex" else { return .unverifiedSafetyCheck }
        // This call's Codex quota/credit response establishes the product
        // context. A provider name, plan name, creator ID, or current login
        // alone cannot establish how a historical request was authenticated.
        let window = ["primary", "secondary"].contains { key in
            guard let value = dictionaryValue(limits[key]),
                  let used = TokenUsage.nonnegativeInteger(value["used_percent"]), used <= 100,
                  let minutes = TokenUsage.nonnegativeInteger(value["window_minutes"]), minutes > 0 else { return false }
            return true
        }
        let credits = dictionaryValue(limits["credits"]).map { value in
            ["has_credits", "unlimited"].allSatisfy { key in
                guard let number = value[key] as? NSNumber else { return false }
                return CFGetTypeID(number) == CFBooleanGetTypeID()
            }
        } ?? false
        return window || credits ? .freeSafetyCheck : .unverifiedSafetyCheck
    }
}

public struct AutoReviewUsage: Codable, Sendable {
    public let freeTokens: Int64
    public let unverifiedTokens: Int64
    public let policy: String
    public let policyURL: String
}
