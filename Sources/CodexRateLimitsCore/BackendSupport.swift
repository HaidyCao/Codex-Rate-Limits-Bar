import Foundation

func stringValue(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }
    if let value = value as? String { return value }
    return String(describing: value)
}

func intValue(_ value: Any?) -> Int? {
    if let number = value as? NSNumber {
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(number.stringValue) ?? Int(exactly: number.doubleValue)
    }
    if let value = value as? String { return Int(value) }
    return nil
}

func boolValue(_ value: Any?) -> Bool {
    guard let value, !(value is NSNull) else { return false }
    if let number = value as? NSNumber {
        return CFGetTypeID(number) == CFBooleanGetTypeID() && number.boolValue
    }
    if let value = value as? String { return value == "true" }
    return false
}

func dictionaryValue(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

func arrayValue(_ value: Any?) -> [Any] {
    value as? [Any] ?? []
}

func isoNow() -> String {
    ISO8601DateFormatter().string(from: Date())
}

func isoFromEpochSeconds(_ seconds: Int?) -> String? {
    guard let seconds, validEpochSeconds(Double(seconds)) else { return nil }
    return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
}

// Keep external timestamps within nonnegative, four-digit ISO calendar years.
func validEpochSeconds(_ seconds: Double) -> Bool {
    seconds.isFinite && seconds >= 0 && seconds < 253_402_300_800
}

func parseIsoDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) {
        return date
    }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: value)
}

func errorMessage(_ error: Error) -> String {
    error.localizedDescription
}

func prettyJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return String(data: try encoder.encode(value), encoding: .utf8) ?? "{}"
}

func writeJSON<T: Encodable>(_ value: T) throws {
    print(try prettyJSON(value))
}

func appendSharedLog(_ message: String) {
    let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Logs")
        .appendingPathComponent("Codex Rate Limits Bar.log")
    let timestamp = ISO8601DateFormatter().string(from: Date())
    guard let data = "\(timestamp) \(message)\n".data(using: .utf8) else { return }

    do {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: logURL.path) {
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: logURL, options: .atomic)
        }
    } catch {
        // Logging must never break refresh or CLI output.
    }
}
