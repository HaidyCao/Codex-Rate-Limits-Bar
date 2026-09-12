import Foundation

/// Disk durability is independent of scan completeness and pricing coverage.
/// Missing on snapshots produced by older versions or without a completed scan.
public struct UsageCachePersistence: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case saved, pending, disabled }
    public let status: Status
    public let error: String?
}
