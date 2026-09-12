import Foundation

enum CodexProcess {
    private static func nativeCodexCandidates() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let packageVariants: [(package: String, triple: String)] = [
            ("@openai/codex-darwin-arm64", "aarch64-apple-darwin"),
            ("@openai/codex-darwin-x64", "x86_64-apple-darwin"),
        ]
        var roots: [URL] = []
        let nvmVersions = home
            .appendingPathComponent(".nvm")
            .appendingPathComponent("versions")
            .appendingPathComponent("node")
        if let versions = try? FileManager.default.contentsOfDirectory(at: nvmVersions, includingPropertiesForKeys: nil) {
            roots.append(contentsOf: versions.map {
                $0.appendingPathComponent("lib")
                    .appendingPathComponent("node_modules")
                    .appendingPathComponent("@openai")
                    .appendingPathComponent("codex")
            })
        }
        roots.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/@openai/codex"),
            URL(fileURLWithPath: "/usr/local/lib/node_modules/@openai/codex"),
        ])

        return roots.flatMap { root in
            packageVariants.map { variant in
                root.appendingPathComponent("node_modules")
                    .appendingPathComponent(variant.package)
                    .appendingPathComponent("vendor")
                    .appendingPathComponent(variant.triple)
                    .appendingPathComponent("bin")
                    .appendingPathComponent("codex")
                    .path
            }
        }
    }

    static func managedEnvironment(for executable: String) -> [String: String] {
        let marker = "/node_modules/@openai/codex/node_modules/"
        guard let range = executable.range(of: marker) else {
            return [:]
        }
        let packageRoot = String(executable[..<range.lowerBound]) + "/node_modules/@openai/codex"
        return [
            "CODEX_MANAGED_BY_NPM": "1",
            "CODEX_MANAGED_PACKAGE_ROOT": packageRoot,
        ]
    }

    static func commandSpec() -> (executable: String, arguments: [String]) {
        let candidates = ([ProcessInfo.processInfo.environment["CODEX_BIN"]].compactMap { $0 }
            + nativeCodexCandidates()
            + [
                "/Applications/Codex.app/Contents/Resources/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
            ]).filter { !$0.isEmpty }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return (candidate, [])
        }
        return ("/usr/bin/env", ["codex"])
    }

    static func environment(codexExecutable: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        let path = [
            "/Applications/Codex.app/Contents/Resources",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            env["PATH"] ?? "",
        ].joined(separator: ":")
        env["PATH"] = path
        env.merge(managedEnvironment(for: codexExecutable)) { _, new in new }
        return env
    }

}

final class PipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
