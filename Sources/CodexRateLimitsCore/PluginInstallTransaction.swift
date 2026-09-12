import Foundation

/// Keeps byte-for-byte copies until all file replacements and CLI commands succeed.
final class PluginInstallTransaction {
    let directory: URL
    var keepForRecovery = false
    private let paths: [URL]
    private var snapshots: [(path: URL, backup: URL?)] = []
    private var modified = Set<URL>()
    private let files = FileManager.default

    init(parent: URL, paths: [URL]) throws {
        directory = parent.appendingPathComponent(".codex-usage-monitor-install-\(UUID().uuidString)")
        self.paths = paths
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func capture() throws {
        for (index, path) in paths.enumerated() {
            try Self.checkPath(path)
            var backup: URL?
            if files.fileExists(atPath: path.path) {
                try Self.checkTree(path)
                let copy = directory.appendingPathComponent("backup-\(index)")
                try files.copyItem(at: path, to: copy)
                backup = copy
            }
            snapshots.append((path, backup))
        }
        let recovery = snapshots.map { ["path": $0.path.path, "backup": $0.backup?.lastPathComponent ?? "absent"] }
        try JSONSerialization.data(withJSONObject: recovery, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("recovery.json"), options: .atomic)
    }

    func replace(_ path: URL, with staged: URL) throws {
        try Self.checkPath(path)
        try files.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        willModify(path)
        if files.fileExists(atPath: path.path) {
            // Retain the displaced item until the transaction is complete.
            try files.moveItem(at: path, to: directory.appendingPathComponent("displaced-\(UUID().uuidString)"))
        }
        try files.moveItem(at: staged, to: path)
    }

    func restore() -> [String] {
        var failures: [String] = []
        for snapshot in snapshots.reversed() where modified.contains(snapshot.path) {
            do {
                try Self.checkPath(snapshot.path)
                if let backup = snapshot.backup {
                    let staged = directory.appendingPathComponent("restore-\(UUID().uuidString)")
                    try files.copyItem(at: backup, to: staged)
                    try replace(snapshot.path, with: staged)
                } else if files.fileExists(atPath: snapshot.path.path) {
                    try files.removeItem(at: snapshot.path)
                }
            } catch { failures.append("\(snapshot.path.path): \(errorMessage(error))") }
        }
        return failures
    }

    func willModify(_ path: URL) {
        modified.insert(path)
    }

    func cleanup() {
        guard !keepForRecovery else { return }
        do { try files.removeItem(at: directory) }
        catch { FileHandle.standardError.write(Data("Could not remove plugin staging files: \(directory.path)\n".utf8)) }
    }

    static func checkPath(_ path: URL) throws {
        var current = path
        while current.path != "/" {
            // Foundation may retain these macOS aliases even after resolving a URL.
            if ["/var", "/tmp", "/etc"].contains(current.path) { break }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                    throw RuntimeError("Plugin installation does not replace symbolic links: \(current.path)")
                }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                // Missing paths are created only after validation and backup.
            }
            current.deleteLastPathComponent()
        }
    }

    static func checkTree(_ path: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        let type = attributes[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeDirectory else {
            throw RuntimeError("Plugin installation requires regular files and directories: \(path.path)")
        }
        if type == .typeDirectory {
            for child in try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) {
                try checkTree(child)
            }
        }
    }
}
