import Foundation

public enum CodexCommandLine {
    public static func isCLIInvocation(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        return !first.hasPrefix("-psn_")
    }

    public static func run(arguments: [String]) -> Int32 {
        guard let command = arguments.first else { return 0 }
        do {
            switch command {
            case "rate-limits", "--json":
                try writeJSON(CodexBackend.readRateLimits())
            case "usage":
                try writeJSON(CodexBackend.readTokenUsage())
            case "reset-credits":
                try writeJSON(CodexBackend.readResetCredits())
            case "combined":
                try writeJSON(CodexBackend.readCombined())
            case "local-usage":
                try writeJSON(CodexBackend.readLocalTokenUsage(rebuild: arguments.dropFirst().contains("--rebuild")))
            case "pricing":
                switch Array(arguments.dropFirst()) {
                case []: try writeJSON(PricingCatalog.load().metadata)
                case ["--export-builtin"]: try writeJSON(PricingCatalog.builtin.document)
                case ["--export"]: try writeJSON(PricingCatalog.load().document)
                case let options where options.count == 2 && options[0] == "--validate":
                    let url = URL(fileURLWithPath: (options[1] as NSString).expandingTildeInPath)
                    try writeJSON(PricingCatalog.snapshot(PricingCatalog.read(url), source: "custom", path: url.path, error: nil).metadata)
                default: throw RuntimeError("Usage: pricing [--export | --export-builtin | --validate FILE]")
                }
            case "status":
                try writeJSON(CodexBackend.readStatus())
            case "mcp":
                CodexMCPServer.run()
            case "install-plugin":
                let source = sourcePath(from: Array(arguments.dropFirst()))
                try CodexPluginInstaller.install(sourcePath: source)
            default:
                FileHandle.standardError.write(Data("Unknown command: \(command)\n".utf8))
                return 1
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(errorMessage(error))\n".utf8))
            return 1
        }
    }

    private static func sourcePath(from arguments: [String]) -> String {
        if let index = arguments.firstIndex(of: "--source"),
           arguments.indices.contains(index + 1)
        {
            return arguments[index + 1]
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("plugins")
            .appendingPathComponent("codex-usage-monitor")
            .path
    }
}
