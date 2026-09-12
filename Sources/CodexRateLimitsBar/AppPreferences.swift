import AppKit
import CodexRateLimitsCore
import Foundation

struct AutoLaunchManager {
    static let label = "local.codex.rate-limits-bar.autostart"
    static let preferenceKey = "autoLaunchEnabled"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    static var preferredEnabled: Bool {
        guard UserDefaults.standard.object(forKey: preferenceKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: preferenceKey)
    }

    @discardableResult
    static func applyStoredPreference() throws -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: preferenceKey) == nil {
            defaults.set(true, forKey: preferenceKey)
        }

        let enabled = defaults.bool(forKey: preferenceKey)
        if enabled {
            try enable()
        } else {
            try disable()
        }
        return enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try enable()
        } else {
            try disable()
        }
        UserDefaults.standard.set(enabled, forKey: preferenceKey)
    }

    private static func enable() throws {
        try writePlist()
    }

    private static func disable() throws {
        try runLaunchctl(["bootout", userDomain, plistURL.path], allowFailure: true)
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private static func writePlist() throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-g", appPath],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
    }

    private static var appPath: String {
        let installedApp = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications")
            .appendingPathComponent("Codex Rate Limits Bar.app")
        if FileManager.default.fileExists(atPath: installedApp.path) {
            return installedApp.path
        }
        return Bundle.main.bundlePath
    }

    private static var userDomain: String {
        "gui/\(getuid())"
    }

    private static func runLaunchctl(_ arguments: [String], allowFailure: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 && !allowFailure {
            let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let detail = [stderrText, stdoutText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw RuntimeError(detail.isEmpty ? "launchctl \(arguments.joined(separator: " ")) failed" : detail)
        }
    }
}

struct StatusItemPreferences {
    static let localUsageStatusItemVisibleKey = "localUsageStatusItemVisible"

    static var isLocalUsageStatusItemVisible: Bool {
        guard UserDefaults.standard.object(forKey: localUsageStatusItemVisibleKey) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: localUsageStatusItemVisibleKey)
    }

    static func setLocalUsageStatusItemVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: localUsageStatusItemVisibleKey)
    }
}

struct QuotaAlertPreferences {
    private static let enabledKey = "quotaAlertsEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }
}
