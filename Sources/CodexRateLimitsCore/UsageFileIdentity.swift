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
    static func sessionID(at url: URL) throws -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var line = Data()
        while line.count <= 8 * 1_048_576 {
            try RefreshWork.check()
            guard let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty else { return nil }
            var start = chunk.startIndex
            while let end = chunk[start...].firstIndex(of: 0x0A) {
                line.append(chunk[start..<end])
                guard line.count <= 8 * 1_048_576 else { return nil }
                start = chunk.index(after: end)
                if LocalUsageLog.isBlankLine(line) {
                    line.removeAll(keepingCapacity: true)
                    continue
                }
                guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      event["type"] as? String == "session_meta", let payload = event["payload"] as? [String: Any]
                else { return nil }
                let id = ((payload["id"] as? String) ?? (payload["session_id"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines)
                return id.flatMap { $0.isEmpty ? nil : $0 }
            }
            line.append(chunk[start...])
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
