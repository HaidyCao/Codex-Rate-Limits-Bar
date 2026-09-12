import Foundation
import XCTest
@testable import CodexRateLimitsCore

final class CodexPluginInstallerTests: XCTestCase {
    private var root: URL!
    private var home: URL { root.appendingPathComponent("home") }
    private var profile: URL { home.appendingPathComponent(".codex") }
    private var source: URL { root.appendingPathComponent("source") }
    private var installed: URL { home.appendingPathComponent("plugins/codex-usage-monitor") }
    private var marketplace: URL { home.appendingPathComponent(".agents/plugins/marketplace.json") }
    private var config: URL { profile.appendingPathComponent("config.toml") }
    private var cache: URL { profile.appendingPathComponent("plugins/cache/personal/codex-usage-monitor") }
    private let pluginID = "codex-usage-monitor@personal"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try write(#"{"name":"codex-usage-monitor","version":"0.4.0","mcpServers":"./.mcp.json"}"#, to: source.appendingPathComponent(".codex-plugin/plugin.json"))
        try write(#"{"mcpServers":{"monitor":{"command":"/bin/true"}}}"#, to: source.appendingPathComponent(".mcp.json"))
        try write("old plugin", to: installed.appendingPathComponent("old.txt"))
        try write("{\n  \"name\": \"personal\", \"plugins\": []\n}\n", to: marketplace)
        try write("# Keep this comment\nmodel = \"fixture-model\"\n", to: config)
        try write("old cache", to: cache.appendingPathComponent("old/version.txt"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testMalformedMarketplaceDoesNotReplacePluginOrCallCLI() throws {
        try write("{broken marketplace", to: marketplace)
        var calls: [[String]] = []
        XCTAssertThrowsError(try CodexPluginInstaller.install(sourcePath: source.path, home: home, codexHome: profile) { args in
            calls.append(args)
            return #"{"installed":[]}"#
        })
        XCTAssertEqual(try String(contentsOf: marketplace, encoding: .utf8), "{broken marketplace")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("old.txt").path))
        XCTAssertTrue(calls.isEmpty)
    }

    func testFailedAddRestoresPluginMarketplaceConfigAndCache() throws {
        let originalMarketplace = try Data(contentsOf: marketplace)
        let originalConfig = try Data(contentsOf: config)
        var calls: [String] = []
        XCTAssertThrowsError(try CodexPluginInstaller.install(sourcePath: source.path, home: home, codexHome: profile) { args in
            calls.append(args[1])
            if args[1] == "list" {
                return "{\"installed\":[{\"pluginId\":\"\(self.pluginID)\"}]}"
            }
            try self.write("partial registration", to: self.config)
            if args[1] == "remove" {
                try FileManager.default.removeItem(at: self.cache)
                return "{}"
            }
            try self.write("partial cache", to: self.cache.appendingPathComponent("new/partial.txt"))
            throw RuntimeError("fixture add failed")
        })
        XCTAssertEqual(calls, ["list", "remove", "add"])
        XCTAssertEqual(try Data(contentsOf: marketplace), originalMarketplace)
        XCTAssertEqual(try Data(contentsOf: config), originalConfig)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("old.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("old/version.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("new").path))
    }

    func testInvalidMarketplaceShapesAndDuplicatesRemainUntouched() throws {
        for invalid in ["[]", "{}", #"{"name":"work","plugins":[]}"#,
                        #"{"name":"personal","plugins":{}}"#,
                        #"{"name":"personal","plugins":[false]}"#,
                        #"{"name":"personal","plugins":[{"name":"x","source":{}},{"name":"x","source":{}}]}"#] {
            try write(invalid, to: marketplace)
            XCTAssertThrowsError(try install { _ in XCTFail("CLI called for invalid marketplace"); return "{}" })
            XCTAssertEqual(try String(contentsOf: marketplace, encoding: .utf8), invalid)
            XCTAssertTrue(exists(installed.appendingPathComponent("old.txt")))
        }
    }

    func testInvalidOrMissingSourceManifestAndMCPLeavePreviousInstall() throws {
        let manifest = source.appendingPathComponent(".codex-plugin/plugin.json")
        let original = try Data(contentsOf: manifest)
        for invalid in ["{", "[]", #"{"name":"different","version":"1","mcpServers":"./.mcp.json"}"#,
                        #"{"name":"codex-usage-monitor","version":false,"mcpServers":"./.mcp.json"}"#] {
            try write(invalid, to: manifest)
            XCTAssertThrowsError(try install { _ in XCTFail("CLI called for invalid source"); return "{}" })
            XCTAssertTrue(exists(installed.appendingPathComponent("old.txt")))
        }
        try original.write(to: manifest)
        try FileManager.default.removeItem(at: source.appendingPathComponent(".mcp.json"))
        XCTAssertThrowsError(try install { _ in XCTFail("CLI called with missing MCP file"); return "{}" })
        XCTAssertTrue(exists(installed.appendingPathComponent("old.txt")))
    }

    func testSuccessPreservesOtherEntriesPolicyAndSourceWithUniqueVersion() throws {
        try write(#"{"name":"personal","custom":"keep","plugins":[{"name":"other","source":{"source":"local","path":"./other"},"extra":42},{"name":"codex-usage-monitor","source":{"source":"local","path":"./old"},"policy":{"installation":"NOT_AVAILABLE"},"custom":"keep-target"}]}"#, to: marketplace)
        let old = try object(marketplace)
        let sourceManifest = try Data(contentsOf: source.appendingPathComponent(".codex-plugin/plugin.json"))
        var versions: [String] = []
        for _ in 0..<2 {
            var commands: [String] = []
            try install { args in
                commands.append(args[1])
                if args[1] == "list" { return #"{"installed":[]}"# }
                XCTAssertTrue(self.exists(self.installed.appendingPathComponent(".mcp.json")))
                return "{}"
            }
            XCTAssertEqual(commands, ["list", "add"])
            versions.append(try object(installed.appendingPathComponent(".codex-plugin/plugin.json"))["version"] as! String)
        }
        XCTAssertNotEqual(versions[0], versions[1])
        XCTAssertTrue(versions.allSatisfy { $0.hasPrefix("0.4.0+codex.") })
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(".codex-plugin/plugin.json")), sourceManifest)
        let value = try object(marketplace)
        XCTAssertEqual(value["custom"] as? String, "keep")
        let plugins = value["plugins"] as! [[String: Any]]
        XCTAssertEqual(plugins.count, 2)
        XCTAssertEqual(plugins[0] as NSDictionary, (old["plugins"] as! [[String: Any]])[0] as NSDictionary)
        XCTAssertEqual(plugins[1]["custom"] as? String, "keep-target")
        XCTAssertEqual((plugins[1]["policy"] as? [String: String])?["installation"], "NOT_AVAILABLE")
        XCTAssertFalse(exists(installed.appendingPathComponent("old.txt")))
        XCTAssertTrue(try stagingDirectories().isEmpty)
    }

    func testFirstInstallationCreatesPersonalMarketplace() throws {
        try FileManager.default.removeItem(at: home)
        var commands: [String] = []
        try install { args in
            commands.append(args[1])
            return args[1] == "list" ? #"{"installed":[]}"# : "{}"
        }
        XCTAssertEqual(commands, ["list", "add"])
        XCTAssertEqual(try object(marketplace)["name"] as? String, "personal")
        XCTAssertTrue(exists(installed.appendingPathComponent(".mcp.json")))
    }

    func testFailedFirstInstallationRemovesPartialFiles() throws {
        try FileManager.default.removeItem(at: home)
        XCTAssertThrowsError(try install { args in
            if args[1] == "list" { return #"{"installed":[]}"# }
            try self.write("partial", to: self.config)
            try self.write("partial", to: self.cache.appendingPathComponent("partial"))
            throw RuntimeError("first add failed")
        })
        for path in [installed, marketplace, config, cache] { XCTAssertFalse(exists(path), path.path) }
        XCTAssertTrue(try stagingDirectories().isEmpty)
    }

    func testListFailureOrInvalidResponseDoesNotRemoveOldPlugin() throws {
        let original = try Data(contentsOf: marketplace)
        for response in ["throw", "{}", "[]", #"{"installed":[{}]}"#, "bad JSON"] {
            var commands: [String] = []
            XCTAssertThrowsError(try install { args in
                commands.append(args[1])
                if response == "throw" { throw RuntimeError("list failed") }
                return response
            })
            XCTAssertEqual(commands, ["list"])
            XCTAssertEqual(try Data(contentsOf: marketplace), original)
            XCTAssertTrue(exists(installed.appendingPathComponent("old.txt")))
            XCTAssertTrue(try stagingDirectories().isEmpty)
        }
    }

    func testRemoveFailureRollsBackAndDoesNotAttemptAdd() throws {
        let originalConfig = try Data(contentsOf: config)
        var commands: [String] = []
        XCTAssertThrowsError(try install { args in
            commands.append(args[1])
            if args[1] == "list" { return "{\"installed\":[{\"pluginId\":\"\(self.pluginID)\"}]}" }
            try self.write("partial remove", to: self.config)
            throw RuntimeError("remove failed")
        })
        XCTAssertEqual(commands, ["list", "remove"])
        XCTAssertEqual(try Data(contentsOf: config), originalConfig)
        XCTAssertTrue(exists(installed.appendingPathComponent("old.txt")))
    }

    func testSymbolicLinksAndOverlappingSourceAreRejected() throws {
        let linked = source.appendingPathComponent("linked-manifest")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: config)
        XCTAssertThrowsError(try install { _ in XCTFail("CLI called with symlink"); return "{}" })
        try FileManager.default.removeItem(at: linked)
        try FileManager.default.removeItem(at: marketplace)
        try FileManager.default.createSymbolicLink(at: marketplace, withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try install { _ in XCTFail("CLI called with dangling marketplace link"); return "{}" })
        try FileManager.default.removeItem(at: marketplace)
        XCTAssertThrowsError(try CodexPluginInstaller.install(sourcePath: installed.path, home: home, codexHome: profile) { _ in
            XCTFail("CLI called with overlapping paths"); return "{}"
        })
        XCTAssertTrue(exists(installed.appendingPathComponent("old.txt")))
    }

    func testRollbackFailureRetainsRecoveryCopiesAndRestoresOtherFiles() throws {
        var message = ""
        XCTAssertThrowsError(try install { args in
            if args[1] == "list" { return #"{"installed":[]}"# }
            try FileManager.default.removeItem(at: self.marketplace.deletingLastPathComponent())
            try self.write("blocks rollback", to: self.marketplace.deletingLastPathComponent())
            try self.write("partial", to: self.config)
            throw RuntimeError("add failed")
        }) { message = errorMessage($0) }
        XCTAssertTrue(message.contains("Rollback incomplete"), message)
        XCTAssertTrue(message.contains("Recovery files:"), message)
        XCTAssertTrue(exists(installed.appendingPathComponent("old.txt")))
        let backups = try stagingDirectories()
        XCTAssertEqual(backups.count, 1)
        let backup = try XCTUnwrap(backups.first)
        XCTAssertTrue(exists(backup.appendingPathComponent("recovery.json")))
        XCTAssertTrue(exists(backup.appendingPathComponent("backup-1")))
        let attributes = try FileManager.default.attributesOfItem(atPath: backup.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testConcurrentInstallerIsRejectedWithoutChangingFirstTransaction() throws {
        try install { args in
            if args[1] == "list" {
                XCTAssertThrowsError(try self.install { _ in XCTFail("Second installer reached CLI"); return "{}" }) {
                    XCTAssertTrue(errorMessage($0).contains("Another plugin installation"))
                }
                return #"{"installed":[]}"#
            }
            return "{}"
        }
        XCTAssertTrue(exists(installed.appendingPathComponent(".mcp.json")))
    }

    func testMarketplaceChangedWhileListingIsPreserved() throws {
        let edited = #"{"name":"personal","plugins":[],"edited":"keep"}"#
        XCTAssertThrowsError(try install { args in
            XCTAssertEqual(args[1], "list")
            try self.write(edited, to: self.marketplace)
            return #"{"installed":[]}"#
        })
        XCTAssertEqual(try String(contentsOf: marketplace, encoding: .utf8), edited)
        XCTAssertTrue(exists(installed.appendingPathComponent("old.txt")))
    }

    func testUnreadableSourceDoesNotReplaceInstalledFiles() throws {
        let path = source.appendingPathComponent(".mcp.json")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
        XCTAssertThrowsError(try install { _ in XCTFail("CLI called with unreadable source"); return "{}" })
        XCTAssertTrue(exists(installed.appendingPathComponent("old.txt")))
    }

    func testProfileInsideInstalledPluginIsRejectedBeforeReplacement() throws {
        XCTAssertThrowsError(try CodexPluginInstaller.install(sourcePath: source.path, home: home, codexHome: installed) { _ in
            XCTFail("CLI called with overlapping Codex profile"); return "{}"
        }) {
            XCTAssertTrue(errorMessage($0).contains("profile must be separate"))
        }
        XCTAssertTrue(exists(installed.appendingPathComponent("old.txt")))
    }

    func testBackupFailureLeavesLiveFilesUntouched() throws {
        let original = try Data(contentsOf: marketplace)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: config.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path) }
        XCTAssertThrowsError(try install { _ in XCTFail("CLI called before backup completed"); return "{}" })
        XCTAssertEqual(try Data(contentsOf: marketplace), original)
        XCTAssertTrue(exists(installed.appendingPathComponent("old.txt")))
        XCTAssertTrue(try stagingDirectories().isEmpty)
    }

    private func install(_ run: @escaping ([String]) throws -> String) throws {
        try CodexPluginInstaller.install(sourcePath: source.path, home: home, codexHome: profile, run: run)
    }

    private func exists(_ path: URL) -> Bool { FileManager.default.fileExists(atPath: path.path) }

    private func object(_ path: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
    }

    private func stagingDirectories() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: installed.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".codex-usage-monitor-install-") }
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
