import Foundation

enum CodexPluginInstaller {
    static func install(sourcePath: String) throws {
        let pluginName = "codex-usage-monitor"
        let marketplaceName = "personal"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let pluginSource = URL(fileURLWithPath: sourcePath)
        let installedPluginParent = home.appendingPathComponent("plugins")
        let installedPluginPath = installedPluginParent.appendingPathComponent(pluginName)
        let marketplacePath = home
            .appendingPathComponent(".agents")
            .appendingPathComponent("plugins")
            .appendingPathComponent("marketplace.json")

        guard FileManager.default.fileExists(atPath: pluginSource.appendingPathComponent(".codex-plugin/plugin.json").path) else {
            throw RuntimeError("Plugin source is missing: \(pluginSource.path)")
        }

        try FileManager.default.createDirectory(at: installedPluginParent, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: installedPluginPath)
        try FileManager.default.copyItem(at: pluginSource, to: installedPluginPath)
        try stampInstalledPluginVersion(installedPluginPath: installedPluginPath)
        try ensureMarketplace(marketplacePath: marketplacePath, pluginName: pluginName, marketplaceName: marketplaceName)
        try refreshCodexPlugin(pluginId: "\(pluginName)@\(marketplaceName)")

        print("Installed \(pluginName)@\(marketplaceName)")
        print("Marketplace: \(marketplacePath.path)")
        print("Plugin files: \(installedPluginPath.path)")
    }

    private static func stampInstalledPluginVersion(installedPluginPath: URL) throws {
        let manifestPath = installedPluginPath.appendingPathComponent(".codex-plugin/plugin.json")
        var manifest = try readJSONObject(manifestPath)
        let version = stringValue(manifest["version"]) ?? "0.1.0"
        let baseVersion = version.replacingOccurrences(of: #"\+codex\.\d+$"#, with: "", options: .regularExpression)
        let stampFormatter = DateFormatter()
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        stampFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        stampFormatter.dateFormat = "yyyyMMddHHmmss"
        manifest["version"] = "\(baseVersion)+codex.\(stampFormatter.string(from: Date()))"
        try writeJSONObject(manifest, to: manifestPath)
    }

    private static func ensureMarketplace(marketplacePath: URL, pluginName: String, marketplaceName: String) throws {
        var marketplace = (try? readJSONObject(marketplacePath)) ?? [
            "name": marketplaceName,
            "interface": ["displayName": "Personal"],
            "plugins": [],
        ]
        marketplace["name"] = stringValue(marketplace["name"]) ?? marketplaceName
        marketplace["interface"] = dictionaryValue(marketplace["interface"]) ?? ["displayName": "Personal"]
        var plugins = arrayValue(marketplace["plugins"])
        let entry: [String: Any] = [
            "name": pluginName,
            "source": ["source": "local", "path": "./plugins/\(pluginName)"],
            "policy": ["installation": "AVAILABLE", "authentication": "ON_INSTALL"],
            "category": "Productivity",
        ]
        if let index = plugins.firstIndex(where: { stringValue(dictionaryValue($0)?["name"]) == pluginName }) {
            plugins[index] = entry
        } else {
            plugins.append(entry)
        }
        marketplace["plugins"] = plugins
        try writeJSONObject(marketplace, to: marketplacePath)
    }

    private static func refreshCodexPlugin(pluginId: String) throws {
        if try isInstalled(pluginId: pluginId) {
            _ = try runCodex(args: ["plugin", "remove", pluginId, "--json"], allowFailure: true)
        }
        _ = try runCodex(args: ["plugin", "add", pluginId, "--json"], allowFailure: false)
    }

    private static func isInstalled(pluginId: String) throws -> Bool {
        let output = try runCodex(args: ["plugin", "list", "--json", "--available"], allowFailure: true)
        guard let data = output.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        return arrayValue(payload["installed"]).contains { plugin in
            stringValue(dictionaryValue(plugin)?["pluginId"]) == pluginId
        }
    }

    private static func runCodex(args: [String], allowFailure: Bool) throws -> String {
        let process = Process()
        let spec = CodexProcess.commandSpec()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments + args
        var env = [
            "PATH": "/Applications/Codex.app/Contents/Resources:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
            "NO_COLOR": "1",
        ]
        env.merge(CodexProcess.managedEnvironment(for: spec.executable)) { _, new in new }
        process.environment = env
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdoutCapture = PipeCapture()
        let stderrCapture = PipeCapture()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            stdoutCapture.append(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            stderrCapture.append(handle.availableData)
        }
        try process.run()
        process.waitUntilExit()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        stdoutCapture.append(stdout.fileHandleForReading.readDataToEndOfFile())
        stderrCapture.append(stderr.fileHandleForReading.readDataToEndOfFile())
        let stdoutText = stdoutCapture.text()
        let stderrText = stderrCapture.text()
        if process.terminationStatus != 0 && !allowFailure {
            let detail = [stdoutText, stderrText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw RuntimeError("codex \(args.joined(separator: " ")) failed\(detail.isEmpty ? "" : ":\n\(detail)")")
        }
        return stdoutText
    }

    private static func readJSONObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private static func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }
}
