import Foundation

enum LocalUsagePaths {
    static func localUsageRootURLs(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        if let override = environment["CODEX_SESSIONS_DIR"], !override.isEmpty {
            return [CodexPaths.canonical(URL(fileURLWithPath: override))]
        }
        var homes = [home.appendingPathComponent(".codex"), home.appendingPathComponent(".codex-cli")]
        if let configured = environment["CODEX_HOME"], !configured.isEmpty {
            homes.append(URL(fileURLWithPath: configured))
        }
        var seen = Set<String>()
        return homes.flatMap { root in
            [root.appendingPathComponent("sessions"), root.appendingPathComponent("archived_sessions")]
        }.map(CodexPaths.canonical).filter { seen.insert($0.path).inserted }
    }

    static func weeklyUsageRootURLs(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        if environment["CODEX_SESSIONS_DIR"] != nil {
            return localUsageRootURLs(environment: environment, home: home)
        }
        let activeHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        return ["sessions", "archived_sessions"].map {
            CodexPaths.canonical(activeHome.appendingPathComponent($0))
        }
    }

    static func localUsageCacheURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        guard environment["CODEX_SESSIONS_DIR"] == nil else { return nil }
        let defaultHome = CodexPaths.canonical(home.appendingPathComponent(".codex"))
        let activeHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : CodexPaths.canonical(URL(fileURLWithPath: $0)) } ?? defaultHome
        var filename = "local-usage-cache.json"
        if activeHome != defaultHome {
            // Stable, non-security identifier. Swift Hasher changes across runs.
            let identifier = activeHome.path.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
                ($0 ^ UInt64($1)) &* 1_099_511_628_211
            }
            filename = "local-usage-cache-\(String(identifier, radix: 16)).json"
        }
        return home.appendingPathComponent("Library/Application Support/Codex Rate Limits Bar")
            .appendingPathComponent(filename)
    }

    static func localUsageSourceDescription(rootURLs: [URL]) -> String {
        rootURLs.map(\.path).joined(separator: ",")
    }

}
