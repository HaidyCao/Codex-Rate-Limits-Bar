import CryptoKit
import Darwin
import Foundation

struct UsageFileStamp: Codable, Equatable {
    let identity: String
    let size: UInt64
    let modifiedAt: Date
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    static func read(_ url: URL) -> UsageFileStamp? {
        var value = stat()
        guard stat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { return nil }
        return UsageFileStamp(identity: "\(value.st_dev):\(value.st_ino)", size: UInt64(max(0, value.st_size)),
                              modifiedAt: Date(timeIntervalSince1970: Double(value.st_mtimespec.tv_sec)
                                               + Double(value.st_mtimespec.tv_nsec) / 1_000_000_000),
                              changeSeconds: Int64(value.st_ctimespec.tv_sec), changeNanoseconds: Int64(value.st_ctimespec.tv_nsec))
    }
}

enum UsageFileIdentity {
    static func sessionID(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var line = Data()
        while line.count <= 8 * 1_048_576 {
            guard let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty else { return nil }
            if let end = chunk.firstIndex(of: 0x0A) {
                line.append(chunk.prefix(upTo: end))
                guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      event["type"] as? String == "session_meta", let payload = event["payload"] as? [String: Any]
                else { return nil }
                let id = ((payload["id"] as? String) ?? (payload["session_id"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines)
                return id.flatMap { $0.isEmpty ? nil : $0 }
            }
            line.append(chunk)
        }
        return nil
    }

    static func prefixHasher(_ handle: FileHandle, count: UInt64) throws -> SHA256 {
        try handle.seek(toOffset: 0)
        var remaining = count
        var hasher = SHA256()
        while remaining > 0 {
            try autoreleasepool {
                try RefreshWork.check()
                guard let chunk = try handle.read(upToCount: Int(min(remaining, 1_048_576))), !chunk.isEmpty else {
                    throw RuntimeError("Session file ended while verifying its cached prefix")
                }
                hasher.update(data: chunk)
                remaining -= UInt64(chunk.count)
            }
        }
        return hasher
    }

    static func digest(_ hasher: SHA256) -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Used only while replaying a session that has multiple physical copies.
/// Persist compact totals, not individual token events or this temporary ledger.
final class UsageCopyLedger {
    struct Contribution {
        var usage: TokenUsage
        let model: String?
        let tier: String?
        let requestInput: Int64?
        let timestamp: String?
        var dailyOwner: String?
        var weeklyOwner: String?
    }
    private(set) var contributions: [Data: Contribution] = [:]
    private var dailyOwners: [Data: String] = [:]
    var path = ""
    var isWeeklySource = false

    func record(key: Data, usage: TokenUsage, model: String?, tier: String?, requestInput: Int64?,
                timestamp: String?, today: Bool, weekly: Bool) {
        guard today || (weekly && isWeeklySource) else { return }
        var contribution = contributions[key] ?? Contribution(usage: usage, model: model, tier: tier,
                                                               requestInput: requestInput, timestamp: timestamp)
        // A copy may omit intermediate cumulative samples. The most precise
        // observed delta wins, independently of filename or scan order.
        if usage.totalTokens < contribution.usage.totalTokens { contribution.usage = usage }
        if today, contribution.dailyOwner == nil { contribution.dailyOwner = path }
        if weekly, isWeeklySource, contribution.weeklyOwner == nil { contribution.weeklyOwner = path }
        contributions[key] = contribution
    }

    func claimDaily(_ key: Data) -> Bool {
        if let owner = dailyOwners[key] { return owner == path }
        dailyOwners[key] = path
        return true
    }

    static func eventKey(session: String?, activeSession: String?, timestamp: Date?, usage: TokenUsage,
                         model: String?, tier: String?, requestInput: Int64?, imported: Bool) -> Data {
        struct Identity: Encodable {
            let session: String?
            let activeSession: String?
            let timestamp: Date?
            let usage: TokenUsage
            let model: String?
            let tier: String?
            let requestInput: Int64?
            let imported: Bool
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let value = Identity(session: session, activeSession: activeSession, timestamp: timestamp, usage: usage,
                             model: model, tier: tier, requestInput: requestInput, imported: imported)
        return Data(SHA256.hash(data: try! encoder.encode(value)))
    }
}
