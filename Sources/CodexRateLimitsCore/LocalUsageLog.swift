import Darwin
import Foundation

struct JsonlFileInfo {
    let url: URL
    let stamp: UsageFileStamp
    var sessionID: String?
    var modifiedAt: Date { stamp.modifiedAt }
    var size: UInt64 { stamp.size }
}

struct JsonlDiscovery {
    var files: [JsonlFileInfo]
    var root: UsageRootStatus
    var issues: [UsageScanIssue]
}


enum LocalUsageLog {
    /// Owned by one scanner and accessed only while that scanner holds its lock.
    /// Constructing ISO parsers per token event dominates dense copied histories.
    final class TimestampParser {
        private let fractional = ISO8601DateFormatter()
        private let plain = ISO8601DateFormatter()

        init() {
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            plain.formatOptions = [.withInternetDateTime]
        }

        func parse(_ value: String?) -> Date? {
            guard let value else { return nil }
            return fractional.date(from: value) ?? plain.date(from: value)
        }
    }

    static func isBlankLine(_ data: Data) -> Bool {
        data.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D || $0 == 0x0A }
    }

    static func walkJsonlFileInfos(root: URL, dayStart: Date, allowMissing: Bool) throws -> JsonlDiscovery {
        var info = stat()
        let result = stat(root.path, &info)
        let missing = result != 0 && errno == ENOENT
        guard result == 0, info.st_mode & S_IFMT == S_IFDIR, access(root.path, R_OK | X_OK) == 0 else {
            return JsonlDiscovery(files: [], root: UsageRootStatus(path: root.path, state: missing ? .missing : .unavailable,
                                                                   optional: allowMissing),
                                  issues: missing && allowMissing ? [] : [UsageScanIssue(kind: .directoryUnavailable, path: root.path,
                                     count: 1, message: missing ? "Session directory does not exist." : "Session directory cannot be read.")])
        }
        var issues: [UsageScanIssue] = []
        let rootStatus = UsageRootStatus(path: root.path, state: .available, optional: allowMissing)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles], errorHandler: { url, error in
            issues.append(UsageScanIssue(kind: .directoryUnavailable, path: url.path, count: 1, message: error.localizedDescription))
            return true
        }) else {
            return JsonlDiscovery(files: [], root: rootStatus,
                                  issues: [UsageScanIssue(kind: .directoryUnavailable, path: root.path, count: 1,
                                                         message: "Session directory enumeration failed.")])
        }
        var files: [JsonlFileInfo] = []
        for case let file as URL in enumerator {
            try RefreshWork.check()
            guard file.pathExtension == "jsonl" else { continue }
            let canonical = file.standardizedFileURL.resolvingSymlinksInPath()
            guard let stamp = UsageFileStamp.read(canonical) else {
                issues.append(UsageScanIssue(kind: .fileReadFailed, path: canonical.path, count: 1,
                                            message: "Session file metadata is unavailable or the path is not a regular file."))
                continue
            }
            guard stamp.modifiedAt >= dayStart else { continue }
            files.append(JsonlFileInfo(url: canonical, stamp: stamp))
        }
        return JsonlDiscovery(files: files, root: rootStatus, issues: issues)
    }

    static func sessionIdFromMeta(_ event: [String: Any]) -> String? {
        guard stringValue(event["type"]) == "session_meta",
              let payload = dictionaryValue(event["payload"])
        else {
            return nil
        }
        let id = (stringValue(payload["id"]) ?? stringValue(payload["session_id"]))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func modelFromPayload(_ payload: [String: Any]) -> String? {
        if let model = stringValue(payload["model"]), !model.isEmpty {
            return model
        }
        for key in ["thread_settings", "settings"] {
            if let nested = dictionaryValue(payload[key]),
               let model = stringValue(nested["model"]),
               !model.isEmpty {
                return model
            }
        }
        if let collaboration = dictionaryValue(payload["collaboration_mode"]),
           let settings = dictionaryValue(collaboration["settings"]),
           let model = stringValue(settings["model"]),
           !model.isEmpty {
            return model
        }
        return nil
    }

    static func hasServiceTierSetting(_ payload: [String: Any]) -> Bool {
        if payload.keys.contains("service_tier") || payload.keys.contains("serviceTier") { return true }
        for key in ["thread_settings", "settings", "collaboration_mode"] {
            if let nested = dictionaryValue(payload[key]), hasServiceTierSetting(nested) { return true }
        }
        return false
    }

    static func serviceTierFromPayload(_ payload: [String: Any]) -> String? {
        for key in ["service_tier", "serviceTier"] {
            if let tier = stringValue(payload[key]), !tier.isEmpty { return tier }
        }
        for key in ["thread_settings", "settings"] {
            if let nested = dictionaryValue(payload[key]), let tier = serviceTierFromPayload(nested) { return tier }
        }
        if let collaboration = dictionaryValue(payload["collaboration_mode"]),
           let settings = dictionaryValue(collaboration["settings"]) {
            return serviceTierFromPayload(settings)
        }
        return nil
    }

    static func usageRegressed(_ previous: TokenUsage?, _ current: TokenUsage) -> Bool {
        guard let previous else { return false }
        return current.totalTokens < previous.totalTokens
    }

    static func maxTokenUsage(_ previous: TokenUsage?, _ current: TokenUsage) -> TokenUsage {
        guard let previous else { return current }
        return TokenUsage(
            inputTokens: max(previous.inputTokens, current.inputTokens),
            cachedInputTokens: max(previous.cachedInputTokens, current.cachedInputTokens),
            cacheWriteInputTokens: max(previous.cacheWriteInputTokens, current.cacheWriteInputTokens),
            outputTokens: max(previous.outputTokens, current.outputTokens),
            reasoningOutputTokens: max(previous.reasoningOutputTokens, current.reasoningOutputTokens),
            totalTokens: max(previous.totalTokens, current.totalTokens),
            breakdownUnavailable: current.hasCompleteBreakdown ? nil : true
        )
    }

    static func positiveDelta(_ previous: TokenUsage?, _ current: TokenUsage, sameSession: Bool) -> TokenUsage? {
        if previous != nil && sameSession && usageRegressed(previous, current) {
            return nil
        }
        let previous = previous ?? TokenUsage()
        let delta = TokenUsage(
            inputTokens: current.inputTokens >= previous.inputTokens ? current.inputTokens - previous.inputTokens : (sameSession ? 0 : current.inputTokens),
            cachedInputTokens: current.cachedInputTokens >= previous.cachedInputTokens ? current.cachedInputTokens - previous.cachedInputTokens : (sameSession ? 0 : current.cachedInputTokens),
            cacheWriteInputTokens: current.cacheWriteInputTokens >= previous.cacheWriteInputTokens ? current.cacheWriteInputTokens - previous.cacheWriteInputTokens : (sameSession ? 0 : current.cacheWriteInputTokens),
            outputTokens: current.outputTokens >= previous.outputTokens ? current.outputTokens - previous.outputTokens : (sameSession ? 0 : current.outputTokens),
            reasoningOutputTokens: current.reasoningOutputTokens >= previous.reasoningOutputTokens ? current.reasoningOutputTokens - previous.reasoningOutputTokens : (sameSession ? 0 : current.reasoningOutputTokens),
            totalTokens: current.totalTokens >= previous.totalTokens ? current.totalTokens - previous.totalTokens : (sameSession ? 0 : current.totalTokens),
            breakdownUnavailable: previous.hasCompleteBreakdown && current.hasCompleteBreakdown ? nil : true
        )
        return delta.inputTokens > 0
            || delta.cachedInputTokens > 0
            || delta.cacheWriteInputTokens > 0
            || delta.outputTokens > 0
            || delta.reasoningOutputTokens > 0
            || delta.totalTokens > 0 ? delta : nil
    }

}
