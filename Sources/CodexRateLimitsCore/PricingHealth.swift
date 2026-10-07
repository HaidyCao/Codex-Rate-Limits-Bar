import Foundation

// Maintenance diagnostics are deliberately separate from pricing snapshots and
// cache signatures. Crossing a review date must never change a price.
struct PricingHealthReport: Encodable {
    let schemaVersion = 1
    let checkedOn: String
    let configurationStatus: String
    let active: UsagePricingMetadata
    let builtin: UsagePricingMetadata
    let api: PricingCardComparison
    let credits: PricingCardComparison
    let builtinPolicyReviews: [PricingPolicyReview]
}

struct PricingCardComparison: Encodable {
    struct RateDifference: Encodable {
        let model: String
        let builtinRate: PricingRate
        let activeRate: PricingRate
    }
    struct ResolutionDifference: Encodable {
        let name: String
        let builtinModel: String
        let activeModel: String
    }
    struct MissingModes: Encodable {
        let model: String
        let serviceTiers: [String]
    }

    let missingModels: [String]
    let additionalModels: [String]
    let missingAliases: [String]
    let additionalAliases: [String]
    let resolutionDifferences: [ResolutionDifference]
    let rateDifferences: [RateDifference]
    let missingServiceTiers: [MissingModes]

    var coverageReviewRecommended: Bool {
        !missingModels.isEmpty || !missingAliases.isEmpty || !missingServiceTiers.isEmpty
    }

    // Include the actionable flag as well as the details in CLI JSON.
    enum CodingKeys: CodingKey {
        case missingModels, additionalModels, missingAliases, additionalAliases
        case resolutionDifferences, rateDifferences, missingServiceTiers, coverageReviewRecommended
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(missingModels, forKey: .missingModels)
        try container.encode(additionalModels, forKey: .additionalModels)
        try container.encode(missingAliases, forKey: .missingAliases)
        try container.encode(additionalAliases, forKey: .additionalAliases)
        try container.encode(resolutionDifferences, forKey: .resolutionDifferences)
        try container.encode(rateDifferences, forKey: .rateDifferences)
        try container.encode(missingServiceTiers, forKey: .missingServiceTiers)
        try container.encode(coverageReviewRecommended, forKey: .coverageReviewRecommended)
    }

    init(active: PricingCard, builtin: PricingCard) {
        // Compare lookup behavior: an explicit alias can legitimately provide a
        // built-in model name, and a direct rate can provide a built-in alias.
        missingModels = builtin.models.keys.filter { active.rate($0) == nil }.sorted()
        additionalModels = active.models.keys.filter { builtin.rate($0) == nil }.sorted()
        missingAliases = builtin.aliases.keys.filter { active.rate($0) == nil }.sorted()
        additionalAliases = active.aliases.keys.filter { builtin.rate($0) == nil }.sorted()
        let names = Set(builtin.models.keys).union(builtin.aliases.keys).sorted()
        resolutionDifferences = names.compactMap { name in
            guard let original = builtin.canonical(name), let selected = active.canonical(name),
                  original != selected else { return nil }
            return ResolutionDifference(name: name, builtinModel: original, activeModel: selected)
        }
        rateDifferences = names.compactMap { name in
            guard let original = builtin.rate(name), let selected = active.rate(name),
                  PricingCatalog.digest(original) != PricingCatalog.digest(selected) else { return nil }
            return RateDifference(model: name, builtinRate: original, activeRate: selected)
        }
        missingServiceTiers = names.compactMap { name in
            guard let original = builtin.rate(name), let selected = active.rate(name) else { return nil }
            let missing = Set(original.serviceTiers?.keys.map { $0 } ?? [])
                .subtracting(selected.serviceTiers?.keys.map { $0 } ?? []).sorted()
            return missing.isEmpty ? nil : MissingModes(model: name, serviceTiers: missing)
        }
    }
}

struct PricingPolicyReview: Encodable {
    let id: String
    let models: [String]
    let products: [String]
    let verifiedAt: String
    let suggestedReviewOn: String
    let announcedProductChangeOn: String?
    // Unknown dates are omitted. A promotion's minimum duration does not
    // establish when its price ends or when another price starts.
    let priceEffectiveOn: String?
    let priceExpiresOn: String?
    let sources: [String]
    let guidance: String
    let reviewDue: Bool
}

enum PricingHealth {
    static func report(_ snapshot: PricingSnapshot, now: Date = Date()) -> PricingHealthReport {
        // Date-only maintenance deadlines use UTC consistently across clients.
        let day = String(ISO8601DateFormatter().string(from: now).prefix(10))
        let builtin = PricingCatalog.builtin
        return PricingHealthReport(checkedOn: day,
            configurationStatus: snapshot.metadata.configurationError == nil ? "valid" : "fallback",
            active: snapshot.metadata, builtin: builtin.metadata,
            api: PricingCardComparison(active: snapshot.document.api, builtin: builtin.document.api),
            credits: PricingCardComparison(active: snapshot.document.credits, builtin: builtin.document.credits),
            builtinPolicyReviews: [
                PricingPolicyReview(id: "gpt-5.5-product-retirement", models: ["gpt-5.5"],
                    products: ["ChatGPT", "ChatGPT Work", "Codex"], verifiedAt: "2026-10-06",
                    suggestedReviewOn: "2026-10-14", announcedProductChangeOn: "2026-10-14",
                    priceEffectiveOn: nil, priceExpiresOn: nil,
                    sources: ["https://learn.chatgpt.com/docs/agent-configuration/speed#retirement-and-migration"],
                    guidance: "Review product availability. API access is unaffected; retain model rates for historical logs. This is not a price expiry.",
                    reviewDue: day >= "2026-10-14"),
                PricingPolicyReview(id: "gpt-5.6-sol-promotion", models: ["gpt-5.6-sol"],
                    products: ["Standard API equivalents", "Purchased-credit equivalents"], verifiedAt: "2026-10-06",
                    suggestedReviewOn: "2026-11-21", announcedProductChangeOn: nil,
                    priceEffectiveOn: nil, priceExpiresOn: nil,
                    sources: ["https://developers.openai.com/api/docs/pricing", "https://learn.chatgpt.com/docs/pricing"],
                    guidance: "The promotion is available at least through 2026-11-21. Recheck official sources; no later price or expiry is established. Keep configured rates until explicitly updated.",
                    reviewDue: day >= "2026-11-21")
            ])
    }
}
