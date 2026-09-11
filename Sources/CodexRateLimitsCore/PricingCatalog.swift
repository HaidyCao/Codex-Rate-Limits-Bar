import CryptoKit
import Foundation

public struct PricingCardMetadata: Codable, Equatable, Sendable {
    public let version: String
    public let verifiedAt: String
    public let sources: [String]
    public let conditions: [String]
}

public struct UsagePricingMetadata: Codable, Equatable, Sendable {
    public let source: String
    public let configurationPath: String?
    public let configurationError: String?
    public let fingerprint: String
    public let basis: String
    public let api: PricingCardMetadata
    public let credits: PricingCardMetadata
    public var previousFingerprint: String? = nil
    public var previousAPIVersion: String? = nil
    public var previousCreditsVersion: String? = nil
    public var changedAtIso: String? = nil
}

public struct UnpricedUsage: Codable, Sendable {
    public let kind: String
    public let model: String
    public let serviceTier: String?
    public let reason: String
    public let totalTokens: Int64
    public let percent: Double
}

struct PricingRate: Codable, Sendable {
    struct ContextTier: Codable, Sendable {
        var threshold: Int64
        var inputMultiplier: Double
        var outputMultiplier: Double
    }
    var input: Double
    var cachedInput: Double
    var cacheWriteInput: Double
    var output: Double
    var datedSnapshots: Bool
    var contextTier: ContextTier?
    var maximumInputTokens: Int64?
    var serviceTiers: [String: Double]?

    var needsContext: Bool { contextTier != nil || maximumInputTokens != nil }

    func estimate(_ usage: TokenUsage, requestInput: Int64?, multiplier: Double = 1) -> Double? {
        if let maximumInputTokens, let requestInput, requestInput > maximumInputTokens { return nil }
        let long = contextTier.map { (requestInput ?? 0) > $0.threshold } == true
        let inputCost = Double(usage.uncachedInputTokens) * input
            + Double(usage.cachedInputTokens) * cachedInput + Double(usage.cacheWriteInputTokens) * cacheWriteInput
        let value = (inputCost * (long ? contextTier!.inputMultiplier : 1)
            + Double(usage.outputTokens) * output * (long ? contextTier!.outputMultiplier : 1)) * multiplier / 1_000_000
        return value.isFinite ? value : nil
    }
}

struct PricingCard: Codable, Sendable {
    var version: String
    var verifiedAt: String
    var sources: [String]
    var conditions: [String]
    var models: [String: PricingRate]
    var aliases: [String: String]

    var metadata: PricingCardMetadata {
        PricingCardMetadata(version: version, verifiedAt: verifiedAt, sources: sources, conditions: conditions)
    }

    func canonical(_ model: String?) -> String? {
        guard let raw = model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
        if models[raw] != nil { return raw }
        if let target = aliases[raw] { return target }
        guard let suffix = raw.range(of: #"-[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) else { return nil }
        let base = String(raw[..<suffix.lowerBound])
        let target = aliases[base] ?? base
        return models[target]?.datedSnapshots == true ? target : nil
    }

    func rate(_ model: String?) -> PricingRate? { canonical(model).flatMap { models[$0] } }

}

struct PricingDocument: Codable, Sendable {
    var schemaVersion: Int
    var api: PricingCard
    var credits: PricingCard
}

struct PricingSnapshot: Sendable {
    let document: PricingDocument
    let metadata: UsagePricingMetadata
    let apiSignatures: [String: String]
    let creditSignatures: [String: String]
}

enum PricingCatalog {
    static let maximumBytes = 1_048_576
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Codex Rate Limits Bar/pricing.json")

    static let builtin: PricingSnapshot = {
        do {
            let installed = Bundle.main.resourceURL.map { $0.appendingPathComponent("CodexRateLimitsBar_CodexRateLimitsCore.bundle") }
                .flatMap { Bundle(url: $0)?.url(forResource: "pricing", withExtension: "json") }
            guard let url = installed ?? Bundle.module.url(forResource: "pricing", withExtension: "json") else {
                throw RuntimeError("Bundled pricing.json is missing")
            }
            let document = try decode(Data(contentsOf: url))
            return snapshot(document, source: "builtin", path: nil, error: nil)
        } catch { fatalError("Invalid bundled pricing: \(error)") }
    }()

    // Pin one immutable document throughout a scan, including replay and
    // aggregation. Parallel callers cannot change another scan's price rules.
    @TaskLocal static var current: PricingSnapshot = builtin

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> PricingSnapshot {
        let explicit = environment["CODEX_PRICING_FILE"]
        let url = explicit.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? defaultURL
        do {
            let document = try read(url)
            return snapshot(document, source: "custom", path: url.path, error: nil)
        } catch {
            let missing = (error as NSError).domain == NSCocoaErrorDomain
                && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains((error as NSError).code)
            if explicit == nil && missing { return builtin }
            return snapshot(builtin.document, source: "builtin", path: url.path,
                            error: "Custom pricing rejected; using built-in rates. \(error.localizedDescription)")
        }
    }

    static func read(_ url: URL) throws -> PricingDocument {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        return try decode(data)
    }

    static func snapshot(_ document: PricingDocument, source: String, path: String?, error: String?) -> PricingSnapshot {
        PricingSnapshot(document: document, metadata: UsagePricingMetadata(source: source, configurationPath: path,
            configurationError: error, fingerprint: digest(document), basis: "current-rates",
            api: document.api.metadata, credits: document.credits.metadata),
            apiSignatures: Dictionary(uniqueKeysWithValues: document.api.models.map { ($0.key, $0.key + "/" + digest($0.value)) }),
            creditSignatures: Dictionary(uniqueKeysWithValues: document.credits.models.map { ($0.key, $0.key + "/" + digest($0.value)) }))
    }

    static func digest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try! encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ data: Data) throws -> PricingDocument {
        guard data.count <= maximumBytes else { throw RuntimeError("Pricing file exceeds 1 MB") }
        // Reject misspelled settings instead of silently ignoring price rules.
        let object = try JSONSerialization.jsonObject(with: data)
        try rejectDuplicateKeys(data)
        func fields(_ value: Any?, allowed: Set<String>, at path: String) throws -> [String: Any] {
            guard let dictionary = value as? [String: Any] else { throw RuntimeError("\(path) must be an object") }
            let unknown = Set(dictionary.keys).subtracting(allowed)
            guard unknown.isEmpty else { throw RuntimeError("Unknown field at \(path): \(unknown.sorted().joined(separator: ", "))") }
            return dictionary
        }
        let root = try fields(object, allowed: ["schemaVersion", "api", "credits"], at: "pricing")
        for kind in ["api", "credits"] {
            let card = try fields(root[kind], allowed: ["version", "verifiedAt", "sources", "conditions", "models", "aliases"], at: kind)
            guard let models = card["models"] as? [String: Any] else { throw RuntimeError("\(kind).models must be an object") }
            for (model, value) in models {
                let path = "\(kind).models.\(model)"
                let rate = try fields(value, allowed: ["input", "cachedInput", "cacheWriteInput", "output", "datedSnapshots", "contextTier", "maximumInputTokens", "serviceTiers"], at: path)
                if let tier = rate["contextTier"], !(tier is NSNull) {
                    _ = try fields(tier, allowed: ["threshold", "inputMultiplier", "outputMultiplier"], at: path + ".contextTier")
                }
            }
        }
        let document: PricingDocument
        do { document = try JSONDecoder().decode(PricingDocument.self, from: data) }
        catch { throw RuntimeError("Invalid pricing value: \(error)") }
        guard document.schemaVersion == 1 else { throw RuntimeError("Unsupported pricing schemaVersion: \(document.schemaVersion)") }
        for (kind, card) in [("api", document.api), ("credits", document.credits)] {
            func require(_ condition: Bool, _ message: String) throws {
                if !condition { throw RuntimeError("\(kind): \(message)") }
            }
            func validName(_ name: String) -> Bool {
                !name.isEmpty && name.count <= 200 && name == name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            }
            let date = ISO8601DateFormatter().date(from: card.verifiedAt + "T00:00:00Z")
            try require(card.verifiedAt.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil
                && date.map { ISO8601DateFormatter().string(from: $0).hasPrefix(card.verifiedAt + "T") } == true, "verifiedAt must be a valid YYYY-MM-DD date")
            try require(!card.version.isEmpty && card.version.count <= 100 && !card.version.contains(where: { $0.isNewline }), "invalid version")
            try require(!card.sources.isEmpty && card.sources.allSatisfy { value in
                let url = URL(string: value)
                return ["https", "http"].contains(url?.scheme) && url?.host != nil
            }, "sources must contain HTTP(S) URLs")
            try require(!card.conditions.isEmpty && card.conditions.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, "conditions must describe the rates")
            try require(card.models.count <= 1000 && card.aliases.count <= 1000, "too many models or aliases")
            for (name, rate) in card.models {
                try require(validName(name), "invalid model name: \(name)")
                try require([rate.input, rate.cachedInput, rate.cacheWriteInput, rate.output].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1_000_000_000 }, "invalid rate for \(name)")
                if let maximum = rate.maximumInputTokens { try require(maximum > 0, "invalid context maximum for \(name)") }
                if let tier = rate.contextTier {
                    try require(tier.threshold > 0 && [tier.inputMultiplier, tier.outputMultiplier].allSatisfy { $0.isFinite && $0 > 0 && $0 <= 1000 }, "invalid context tier for \(name)")
                    try require(rate.maximumInputTokens.map { $0 > tier.threshold } ?? true, "context maximum must exceed tier threshold for \(name)")
                }
                if kind == "api" { try require(rate.serviceTiers == nil, "API equivalents use Standard rates; serviceTiers belongs to credits") }
                else {
                    try require(rate.serviceTiers?["standard"] == 1, "credits requires serviceTiers.standard = 1 for \(name)")
                    try require(rate.serviceTiers?.allSatisfy { validName($0.key) && $0.value.isFinite && $0.value > 0 && $0.value <= 1000 } == true, "invalid service tier for \(name)")
                }
            }
            for (alias, target) in card.aliases {
                try require(validName(alias) && card.models[alias] == nil && card.models[target] != nil,
                            "alias \(alias) must point directly to a model and cannot shadow one")
            }
        }
        return document
    }

    private static func rejectDuplicateKeys(_ data: Data) throws {
        // Foundation accepts duplicate keys. Validate their uniqueness before
        // decoding prices, including keys written with JSON Unicode escapes.
        // JSONSerialization above has already validated the document grammar.
        let bytes = Array(data)
        var scopes: [Set<String>] = []
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 0x7B: scopes.append([])
            case 0x7D: scopes.removeLast()
            case 0x22:
                let start = index
                index += 1
                while index < bytes.count {
                    if bytes[index] == 0x5C { index += 2; continue }
                    if bytes[index] == 0x22 { break }
                    index += 1
                }
                var next = index + 1
                while next < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[next]) { next += 1 }
                if next < bytes.count, bytes[next] == 0x3A, !scopes.isEmpty {
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
                    let scope = scopes.count - 1
                    guard scopes[scope].insert(key).inserted else { throw RuntimeError("Duplicate pricing key: \(key)") }
                }
            default: break
            }
            index += 1
        }
    }
}
