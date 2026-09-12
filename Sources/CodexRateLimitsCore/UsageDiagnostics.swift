import Foundation

public enum UsageScanStatus: String, Codable, Sendable {
    case complete, empty, noUsage, partial, unavailable

    public var isIncomplete: Bool { self == .partial || self == .unavailable }
}

public struct UsageScanIssue: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case directoryUnavailable, fileReadFailed, fileMissing, invalidJSON, invalidUsage
        case oversizedRecord, pendingRecord, copyReplayIncomplete, cacheUnavailable
    }

    public let kind: Kind
    public let path: String?
    public let count: Int
    public let message: String
}

public struct UsageRootStatus: Codable, Sendable {
    public enum State: String, Codable, Sendable { case available, missing, unavailable }
    public let path: String
    public let state: State
    public let optional: Bool
}

public struct UsageScanDiagnostics: Codable, Sendable {
    public let status: UsageScanStatus
    public let roots: [UsageRootStatus]
    public let filesDiscovered: Int
    public let filesVerified: Int
    public let validUsageEventCount: Int
    public let directoryFailureCount: Int
    public let readFailureCount: Int
    public let missingFileCount: Int
    public let parseErrorCount: Int
    public let skippedRecordCount: Int
    public let pendingRecordCount: Int
    public let issues: [UsageScanIssue]
    public let omittedIssueCount: Int

    static func make(roots: [UsageRootStatus], filesDiscovered: Int, filesVerified: Int,
                     validRecords: Int, usageEvents: Int, issues: [UsageScanIssue]) -> UsageScanDiagnostics {
        func count(_ kind: UsageScanIssue.Kind) -> Int { issues.filter { $0.kind == kind }.reduce(0) { $0 + $1.count } }
        let status: UsageScanStatus = !issues.isEmpty ? (validRecords > 0 ? .partial : .unavailable)
            : filesDiscovered == 0 ? .empty : usageEvents == 0 ? .noUsage : .complete
        return UsageScanDiagnostics(status: status, roots: roots, filesDiscovered: filesDiscovered,
                                    filesVerified: filesVerified, validUsageEventCount: usageEvents,
                                    directoryFailureCount: count(.directoryUnavailable), readFailureCount: count(.fileReadFailed),
                                    missingFileCount: count(.fileMissing), parseErrorCount: count(.invalidJSON),
                                    skippedRecordCount: count(.invalidUsage) + count(.oversizedRecord),
                                    pendingRecordCount: count(.pendingRecord), issues: Array(issues.prefix(50)),
                                    omittedIssueCount: max(0, issues.count - 50))
    }
}

/// Counts share the same deduplicated token denominator. API and credit counts
/// are unions per event, so missing both fields does not count the tokens twice.
public struct UsageBillingAssumptions: Codable, Sendable {
    public var totalTokens: Int64 = 0
    public var missingServiceTierTokens: Int64 = 0
    public var missingRequestContextTokens: Int64 = 0
    public var assumedAPITokens: Int64 = 0
    public var assumedCreditTokens: Int64 = 0

    public var apiPercent: Double { totalTokens > 0 ? 100 * Double(assumedAPITokens) / Double(totalTokens) : 0 }
    public var creditPercent: Double { totalTokens > 0 ? 100 * Double(assumedCreditTokens) / Double(totalTokens) : 0 }

    public func encode(to encoder: Encoder) throws {
        enum Key: String, CodingKey {
            case totalTokens, missingServiceTierTokens, missingRequestContextTokens
            case assumedAPITokens, assumedCreditTokens, apiPercent, creditPercent
        }
        var value = encoder.container(keyedBy: Key.self)
        try value.encode(totalTokens, forKey: .totalTokens)
        try value.encode(missingServiceTierTokens, forKey: .missingServiceTierTokens)
        try value.encode(missingRequestContextTokens, forKey: .missingRequestContextTokens)
        try value.encode(assumedAPITokens, forKey: .assumedAPITokens)
        try value.encode(assumedCreditTokens, forKey: .assumedCreditTokens)
        try value.encode(apiPercent, forKey: .apiPercent)
        try value.encode(creditPercent, forKey: .creditPercent)
    }

    mutating func merge(_ other: UsageBillingAssumptions) {
        totalTokens += other.totalTokens
        missingServiceTierTokens += other.missingServiceTierTokens
        missingRequestContextTokens += other.missingRequestContextTokens
        assumedAPITokens += other.assumedAPITokens
        assumedCreditTokens += other.assumedCreditTokens
    }
}

struct UsageFileDiagnostics: Codable {
    static let currentVersion = 2
    var version = currentVersion
    var validRecords = 0
    var todayUsageEvents = 0
    var invalidUsageRecords = 0
    var oversizedRecords = 0
}
