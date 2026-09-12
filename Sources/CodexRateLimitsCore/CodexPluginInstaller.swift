import Foundation
import Darwin

enum CodexPluginInstaller {
    private static let pluginName = "codex-usage-monitor"
    private static let pluginID = "codex-usage-monitor@personal"

    static func install(
        sourcePath: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        codexHome: URL? = nil,
        run: (([String]) throws -> String)? = nil
    ) throws {
        let files = FileManager.default
        let home = CodexPaths.canonical(home)
        let profile = CodexPaths.canonical(codexHome ?? ProcessInfo.processInfo.environment["CODEX_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex"))
        let source = CodexPaths.canonical(URL(fileURLWithPath: sourcePath))
        let parent = home.appendingPathComponent("plugins")
        let destination = parent.appendingPathComponent(pluginName)
        let marketplace = home.appendingPathComponent(".agents/plugins/marketplace.json")
        let config = profile.appendingPathComponent("config.toml")
        let cache = profile.appendingPathComponent("plugins/cache/personal/\(pluginName)")
        let paths = [destination, marketplace, config, cache]
        for (index, path) in paths.enumerated() {
            guard !paths.dropFirst(index + 1).contains(where: { overlaps(path, $0) }) else {
                throw RuntimeError("Codex profile must be separate from the installed plugin and marketplace")
            }
        }
        for path in paths { try PluginInstallTransaction.checkPath(path) }
        guard !paths.contains(where: { overlaps(source, $0.resolvingSymlinksInPath()) }) else {
            throw RuntimeError("Plugin source must be separate from installed files and configuration: \(source.path)")
        }
        // Decode existing files before creating staging directories or invoking the CLI.
        try validatePlugin(source)
        _ = try updatedMarketplace(at: marketplace)
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let lockPath = parent.appendingPathComponent(".codex-usage-monitor-install.lock")
        let lock = Darwin.open(lockPath.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw RuntimeError("Cannot open plugin installation lock: \(lockPath.path)") }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw RuntimeError("Another plugin installation is running; retry after it finishes.")
        }
        defer { _ = flock(lock, LOCK_UN) }

        let marketplaceData = try updatedMarketplace(at: marketplace)
        let originalMarketplace = try files.fileExists(atPath: marketplace.path) ? Data(contentsOf: marketplace) : nil
        let transaction = try PluginInstallTransaction(parent: parent, paths: paths)
        defer { transaction.cleanup() }
        let stagedPlugin = transaction.directory.appendingPathComponent("new-plugin")
        try files.copyItem(at: source, to: stagedPlugin)
        try validatePlugin(stagedPlugin)
        try stampVersion(at: stagedPlugin)
        let stagedMarketplace = transaction.directory.appendingPathComponent("new-marketplace.json")
        try marketplaceData.write(to: stagedMarketplace)
        if files.fileExists(atPath: marketplace.path) {
            let attributes = try files.attributesOfItem(atPath: marketplace.path)
            try files.setAttributes([.posixPermissions: attributes[.posixPermissions] ?? 0o600], ofItemAtPath: stagedMarketplace.path)
        }
        try transaction.capture()
        let command = run ?? { try CodexPluginCommand.run(args: $0, home: home, codexHome: profile) }
        do {
            transaction.willModify(config)
            transaction.willModify(cache)
            let installed = try isInstalled(run: command)
            // A second installer or editor may have changed the catalog during preparation.
            let currentMarketplace = try files.fileExists(atPath: marketplace.path) ? Data(contentsOf: marketplace) : nil
            guard currentMarketplace == originalMarketplace else {
                throw RuntimeError("Marketplace changed during installation; retry with the updated configuration.")
            }
            try transaction.replace(destination, with: stagedPlugin)
            try transaction.replace(marketplace, with: stagedMarketplace)
            if installed { _ = try command(["plugin", "remove", pluginID, "--json"]) }
            _ = try command(["plugin", "add", pluginID, "--json"])
        } catch {
            let failures = transaction.restore()
            if !failures.isEmpty {
                transaction.keepForRecovery = true
                throw RuntimeError("Plugin installation failed: \(errorMessage(error))\nRollback incomplete: \(failures.joined(separator: "; "))\nRecovery files: \(transaction.directory.path)")
            }
            throw RuntimeError("Plugin installation failed: \(errorMessage(error))\nInstallation changes rolled back; backups restored for affected paths.")
        }
        print("Installed \(pluginID)")
        print("Marketplace: \(marketplace.path)")
        print("Plugin files: \(destination.path)")
    }

    private static func overlaps(_ first: URL, _ second: URL) -> Bool {
        first.path == second.path || first.path.hasPrefix(second.path + "/") || second.path.hasPrefix(first.path + "/")
    }

    private static func validatePlugin(_ root: URL) throws {
        // Copied symlinks could make stamping or a CLI install write outside the bundle.
        try PluginInstallTransaction.checkTree(root)
        let manifestPath = root.appendingPathComponent(".codex-plugin/plugin.json")
        let manifest = try readObject(manifestPath)
        guard manifest["name"] as? String == pluginName,
              let version = manifest["version"] as? String, !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manifest["mcpServers"] as? String == "./.mcp.json"
        else { throw RuntimeError("Invalid bundled plugin name, version or mcpServers path: \(manifestPath.path)") }
        let mcpPath = root.appendingPathComponent(".mcp.json")
        let mcp = try readObject(mcpPath)
        guard let servers = mcp["mcpServers"] as? [String: [String: Any]], !servers.isEmpty,
              servers.values.allSatisfy({ ($0["command"] as? String)?.isEmpty == false })
        else { throw RuntimeError("Invalid bundled MCP server configuration: \(mcpPath.path)") }
    }

    private static func stampVersion(at root: URL) throws {
        let path = root.appendingPathComponent(".codex-plugin/plugin.json")
        var manifest = try readObject(path)
        let version = manifest["version"] as! String // Validated before staging.
        let base = version.replacingOccurrences(of: #"[+.]codex\.[A-Za-z0-9.-]+$"#, with: "", options: .regularExpression)
        let separator = base.contains("+") ? "." : "+"
        manifest["version"] = "\(base)\(separator)codex.\(UUID().uuidString.lowercased())"
        try jsonData(manifest).write(to: path, options: .atomic)
    }

    private static func updatedMarketplace(at path: URL) throws -> Data {
        var value: [String: Any] = ["name": "personal", "interface": ["displayName": "Personal"], "plugins": []]
        if FileManager.default.fileExists(atPath: path.path) { value = try readObject(path) }
        guard value["name"] as? String == "personal",
              var plugins = value["plugins"] as? [[String: Any]],
              value["interface"] == nil || value["interface"] is [String: Any]
        else { throw RuntimeError("Marketplace must have name 'personal' and a plugins array: \(path.path)") }
        var names = Set<String>()
        for plugin in plugins {
            guard let name = plugin["name"] as? String, !name.isEmpty,
                  names.insert(name).inserted, plugin["source"] is [String: Any]
            else { throw RuntimeError("Marketplace has an invalid or duplicate plugin entry: \(path.path)") }
        }
        let index = plugins.firstIndex { $0["name"] as? String == pluginName }
        var entry = index.map { plugins[$0] } ?? [
            "name": pluginName,
            "policy": ["installation": "AVAILABLE", "authentication": "ON_INSTALL"],
            "category": "Productivity",
        ]
        entry["source"] = ["source": "local", "path": "./plugins/\(pluginName)"]
        if let index { plugins[index] = entry } else { plugins.append(entry) }
        value["plugins"] = plugins
        return try jsonData(value)
    }

    private static func isInstalled(run: ([String]) throws -> String) throws -> Bool {
        let output = try run(["plugin", "list", "--json"])
        guard let data = output.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let installed = payload["installed"] as? [[String: Any]],
              installed.allSatisfy({ ($0["pluginId"] as? String)?.isEmpty == false })
        else { throw RuntimeError("codex plugin list returned an invalid installed-plugin list") }
        return installed.contains { $0["pluginId"] as? String == pluginID }
    }

    private static func readObject(_ path: URL) throws -> [String: Any] {
        do {
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] else {
                throw RuntimeError("Expected a JSON object")
            }
            return object
        } catch { throw RuntimeError("Cannot read plugin configuration at \(path.path): \(errorMessage(error))") }
    }

    private static func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8)
    }
}
