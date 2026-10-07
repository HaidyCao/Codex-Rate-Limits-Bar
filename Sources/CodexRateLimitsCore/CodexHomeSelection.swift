import Foundation

public struct CodexHomeCandidate: Equatable, Sendable {
    public let path: String
    public let hasAuthentication: Bool
    public let hasConfiguration: Bool
    public let hasSessions: Bool
    public let isAvailable: Bool

    public var name: String { URL(fileURLWithPath: path).lastPathComponent }

    public func displayPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let prefix = CodexPaths.canonical(home).path + "/"
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }
}

/// Desktop selection is explicit; CLI and MCP continue to honor their environment.
public struct CodexHomeSelection: Codable, Equatable, Sendable {
    public let activeHome: String
    public let localHomes: [String]

    public init(activeHome: URL, localHomes: [URL]) {
        self.activeHome = CodexPaths.canonical(activeHome).path
        self.localHomes = Array(Set((localHomes + [activeHome]).map { CodexPaths.canonical($0).path })).sorted()
    }

    public static func initial(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        let active = home.appendingPathComponent(".codex")
        return Self(activeHome: active, localHomes: CodexHomeDiscovery.discover(home: home).filter(\.isAvailable)
            .map { URL(fileURLWithPath: $0.path) })
    }

    public var localRoots: [URL] {
        localHomes.flatMap { path in
            ["sessions", "archived_sessions"].map { URL(fileURLWithPath: path).appendingPathComponent($0) }
        }
    }

    public var weeklyRoots: [URL] {
        ["sessions", "archived_sessions"].map { URL(fileURLWithPath: activeHome).appendingPathComponent($0) }
    }

    public func environment(overriding base: [String: String]) -> [String: String] {
        var result = base
        result["CODEX_HOME"] = activeHome
        result.removeValue(forKey: "CODEX_SESSIONS_DIR")
        return result
    }

    public var identity: String { CodexAccountContext.digest([activeHome] + localHomes) }

    public func validated() throws -> Self {
        guard activeHome.hasPrefix("/"), localHomes.allSatisfy({ $0.hasPrefix("/") }) else {
            throw RuntimeError("Codex home paths must be absolute.")
        }
        return Self(activeHome: URL(fileURLWithPath: activeHome), localHomes: localHomes.map { URL(fileURLWithPath: $0) })
    }
}

public enum CodexHomeDiscovery {
    /// One directory level only. Inspect marker existence, never credential contents.
    public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                including paths: [String] = []) -> [CodexHomeCandidate] {
        let manager = FileManager.default
        let defaultHome = home.appendingPathComponent(".codex")
        let children = (try? manager.contentsOfDirectory(at: home, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var urls = [defaultHome] + paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
        for child in children {
            let value = candidate(child)
            if value.isAvailable && (value.hasConfiguration && (value.hasAuthentication || value.hasSessions)
                || child.lastPathComponent.lowercased().contains("codex")
                && (value.hasAuthentication || value.hasConfiguration || value.hasSessions)) {
                urls.append(child)
            }
        }
        var seen = Set<String>()
        let preferred = CodexPaths.canonical(defaultHome).path
        return urls.map(candidate).filter { seen.insert($0.path).inserted }.sorted {
            if $0.path == preferred { return $1.path != preferred }
            if $1.path == preferred { return false }
            return $0.path < $1.path
        }
    }

    public static func candidate(_ url: URL) -> CodexHomeCandidate {
        let root = CodexPaths.canonical(url)
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        let available = manager.fileExists(atPath: root.path, isDirectory: &isDirectory)
            && isDirectory.boolValue && manager.isReadableFile(atPath: root.path)
        func file(_ name: String) -> Bool {
            var directory: ObjCBool = false
            return manager.fileExists(atPath: root.appendingPathComponent(name).path, isDirectory: &directory)
                && !directory.boolValue
        }
        func folder(_ name: String) -> Bool {
            var directory: ObjCBool = false
            return manager.fileExists(atPath: root.appendingPathComponent(name).path, isDirectory: &directory)
                && directory.boolValue
        }
        return CodexHomeCandidate(path: root.path, hasAuthentication: file("auth.json"),
            hasConfiguration: file("config.toml"), hasSessions: folder("sessions") || folder("archived_sessions"),
            isAvailable: available)
    }
}
