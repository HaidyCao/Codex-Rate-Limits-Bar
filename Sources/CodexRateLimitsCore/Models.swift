import Foundation

public struct RateLimitWindow: Codable, Sendable {
    public let usedPercent: Int
    public let remainingPercent: Int
    public let windowDurationMins: Int?
    public let resetsAt: Int?
    public let resetsAtIso: String?

    public var resetDate: Date? {
        if let resetsAt {
            return Date(timeIntervalSince1970: TimeInterval(resetsAt))
        }
        guard let resetsAtIso else { return nil }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: resetsAtIso) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: resetsAtIso)
    }
}

public struct CreditsSnapshot: Codable {
    public let hasCredits: Bool
    public let unlimited: Bool
    public let balance: String?
}

public struct RateLimitSnapshot: Codable {
    public let limitId: String?
    public let limitName: String?
    public let planType: String?
    public let rateLimitReachedType: String?
    public let primary: RateLimitWindow?
    public let secondary: RateLimitWindow?
    public let credits: CreditsSnapshot?
    public let individualLimit: JSONValue?

    public var weeklyWindow: RateLimitWindow? {
        if primary?.windowDurationMins == 10_080 {
            return primary
        }
        if secondary?.windowDurationMins == 10_080 {
            return secondary
        }
        return nil
    }
}

public struct RateLimitDisplay: Codable {
    public let primaryLabel: String?
    public let secondaryLabel: String?
    public let primaryRemainingPercent: Int?
    public let secondaryRemainingPercent: Int?
}

public struct RateLimitPayload: Codable {
    public let fetchedAtIso: String
    public let rateLimits: RateLimitSnapshot?
    public let rateLimitsByLimitId: [String: RateLimitSnapshot]?
    public let display: RateLimitDisplay?
    public let resetCredits: ResetCreditsSnapshot?
    public let localUsage: LocalUsageSnapshot?
    public let rateLimitError: String?
    public let localUsageError: String?
    public let usage: JSONValue?
}

public struct ResetCreditItem: Codable {
    public let id: String?
    public let resetType: String?
    public let typeLabel: String?
    public let status: String?
    public let statusLabel: String?
    public let createdAtIso: String?
    public let expiresAtIso: String?
    public let createdAtLabel: String?
    public let expiresAtLabel: String?
    public let createdAtShortLabel: String?
    public let expiresAtShortLabel: String?
}

public struct ResetCreditsDisplay: Codable {
    public let summaryLabel: String?
    public let categoryLabel: String?
    public let detailLabels: [String]?
}

public struct ResetCreditsSnapshot: Codable {
    public let fetchedAtIso: String
    public let availableCount: Int?
    public let credits: [ResetCreditItem]
    public let error: String?
    public let display: ResetCreditsDisplay?
}

public struct LocalUsageDisplay: Codable {
    public let consumptionLabel: String?
    public let cacheHitLabel: String?
}

public struct LocalUsageTopFile: Codable {
    public let file: String
    public let eventCount: Int
    public let duplicateEventCount: Int
    public let importedEventCount: Int
    public let regressionEventCount: Int
    public let primarySessionId: String?
    public let totalTokens: Int64
    public let lastEventAtIso: String?
}

public struct LocalUsageSnapshot: Codable {
    public let fetchedAtIso: String
    public let source: String?
    public let timezone: String?
    public let localDate: String
    public let inputTokens: Int64
    public let cachedInputTokens: Int64
    public let outputTokens: Int64
    public let reasoningOutputTokens: Int64
    public let totalTokens: Int64
    public let cacheHitPercent: Double?
    public let eventCount: Int
    public let duplicateEventCount: Int
    public let importedEventCount: Int
    public let regressionEventCount: Int
    public let filesScanned: Int
    public let filesWithEvents: Int
    public let parseErrorCount: Int
    public let error: String?
    public let topFiles: [LocalUsageTopFile]?
    public let display: LocalUsageDisplay?
}

public struct RuntimeError: Error, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}
