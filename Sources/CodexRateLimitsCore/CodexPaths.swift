import Foundation

/// Foundation can spell the same missing macOS path as /private/var before
/// creation and /var afterwards. Resolve the existing ancestor first so optional
/// directories do not acquire a new identity when they appear.
enum CodexPaths {
    static func canonical(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        while ancestor.path != "/", !FileManager.default.fileExists(atPath: ancestor.path) {
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var result = ancestor.resolvingSymlinksInPath()
        for component in missing.reversed() { result.appendPathComponent(component) }
        return result
    }

    static func canonicalPaths(_ paths: [String]) -> Set<String> {
        Set(paths.map { canonical(URL(fileURLWithPath: $0)).path })
    }
}
