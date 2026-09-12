import CryptoKit
import Foundation

/// Replay copied sessions before aggregating them. Daily and weekly histories
/// have separate source sets; neither can donate or remove the other's usage.
final class UsageCopyLedger {
    static let currentVersion = 1

    struct Contribution {
        let usage: TokenUsage
        let model: String?
        let tier: String?
        let requestInput: Int64?
        let timestamp: String?
        let sampledAt: Date
        let dailyOwner: String?
        let weeklyOwner: String?
    }
    private struct Sample {
        let usage: TokenUsage
        let timestamp: Date
        let timestampText: String?
        let model: String?
        let tier: String?
        let requestInput: Int64?
    }
    private struct OwnedUsage {
        var usage: TokenUsage
        let path: String

        mutating func narrow(to other: TokenUsage) {
            guard other.totalTokens <= usage.totalTokens else { return }
            let unavailable = usage.breakdownUnavailable == true || other.breakdownUnavailable == true
            if other.totalTokens < usage.totalTokens {
                usage = other
            } else {
                // Equally narrow but contradictory component histories cannot
                // certify a price. Retain only their common component counts.
                var previous = usage, candidate = other
                previous.breakdownUnavailable = nil; candidate.breakdownUnavailable = nil
                if previous != candidate {
                    usage = TokenUsage(inputTokens: min(usage.inputTokens, other.inputTokens),
                        cachedInputTokens: min(usage.cachedInputTokens, other.cachedInputTokens),
                        cacheWriteInputTokens: min(usage.cacheWriteInputTokens, other.cacheWriteInputTokens),
                        outputTokens: min(usage.outputTokens, other.outputTokens),
                        reasoningOutputTokens: min(usage.reasoningOutputTokens, other.reasoningOutputTokens),
                        totalTokens: usage.totalTokens, breakdownUnavailable: true)
                }
            }
            if unavailable { usage.breakdownUnavailable = true }
        }
    }
    private struct Trace {
        let path: String
        var keys: [Data] = []
        var positions: [Data: Int] = [:]
    }
    private struct Position {
        let trace: Int
        let index: Int
    }

    private final class History {
        var samples: [Data: Sample] = [:]
        var values: [Data: OwnedUsage] = [:]
        var traces: [Trace] = []
        var currentTraces: [String: Int] = [:]
        var hasConflict = false

        func observe(key: Data, sample: Sample, delta: TokenUsage?, path: String, continuing: Bool, include: Bool) {
            samples[key] = samples[key] ?? sample
            if !continuing || currentTraces[path] == nil {
                currentTraces[path] = traces.count
                traces.append(Trace(path: path))
            }
            let index = currentTraces[path]!
            if traces[index].positions[key] == nil {
                traces[index].positions[key] = traces[index].keys.count
                traces[index].keys.append(key)
            }
            guard include, let delta else { return }
            if values[key] != nil { values[key]?.narrow(to: delta) }
            else { values[key] = OwnedUsage(usage: delta, path: path) }
        }

        func resolve(weekly: Bool) throws -> [Contribution] {
            guard !values.isEmpty else { return [] }
            // Identical physical copies need only one trace for alignment.
            // Ownership has already been recorded for every eligible source.
            var seen: Set<[Data]> = []
            let unique = traces.filter { seen.insert($0.keys).inserted }
            var occurrences: [Data: [Position]] = [:]
            for (trace, value) in unique.enumerated() {
                try RefreshWork.check()
                for (index, key) in value.keys.enumerated() {
                    occurrences[key, default: []].append(Position(trace: trace, index: index))
                }
            }
            for key in occurrences.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                let positions = occurrences[key]!
                guard positions.count > 1 else { continue }
                try RefreshWork.check()
                guard Set(positions.map { unique[$0.trace].path }).count > 1 else { continue }
                let predecessors = Set(positions.map { position -> Data? in
                    position.index > 0 ? unique[position.trace].keys[position.index - 1] : nil
                })
                guard predecessors.count > 1 else { continue }

                // The latest common anchor bounds only these converging
                // traces. Other branches beyond that anchor stay independent.
                let shortest = positions.min { $0.index < $1.index }!
                var anchor: Data?
                for index in stride(from: shortest.index - 1, through: 0, by: -1) {
                    try RefreshWork.check()
                    let candidate = unique[shortest.trace].keys[index]
                    if positions.allSatisfy({ position in
                        unique[position.trace].positions[candidate].map { $0 < position.index } == true
                    }) { anchor = candidate; break }
                }
                var merged: Set<Data> = []
                for position in positions {
                    try RefreshWork.check()
                    let trace = unique[position.trace]
                    let start = anchor.flatMap { trace.positions[$0] } ?? 0
                    merged.formUnion(trace.keys[start...position.index])
                }
                let ordered = merged.sorted { lhs, rhs in
                    let a = samples[lhs]!, b = samples[rhs]!
                    if a.usage.totalTokens != b.usage.totalTokens { return a.usage.totalTokens < b.usage.totalTokens }
                    if a.timestamp != b.timestamp { return a.timestamp < b.timestamp }
                    return lhs.lexicographicallyPrecedes(rhs)
                }
                guard zip(ordered, ordered.dropFirst()).allSatisfy({
                    samples[$0.0]!.timestamp <= samples[$0.1]!.timestamp
                }) else { hasConflict = true; continue }
                for (previous, key) in zip(ordered, ordered.dropFirst()) {
                    guard var value = values[key] else { continue }
                    let refined = LocalUsageLog.positiveDelta(samples[previous]!.usage, samples[key]!.usage, sameSession: true) ?? TokenUsage()
                    value.narrow(to: refined)
                    values[key] = value
                }
            }
            return values.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { key in
                let sample = samples[key]!, value = values[key]!
                return Contribution(usage: value.usage, model: sample.model, tier: sample.tier,
                    requestInput: sample.requestInput, timestamp: sample.timestampText,
                    sampledAt: sample.timestamp,
                    dailyOwner: weekly ? nil : value.path, weeklyOwner: weekly ? value.path : nil)
            }
        }
    }

    private let daily = History()
    private let weekly = History()
    private let trackWeekly: Bool
    private var dailyOwners: [Data: String] = [:]
    var path = ""
    var isWeeklySource = false
    var hasDailyConflict: Bool { daily.hasConflict }
    var hasWeeklyConflict: Bool { weekly.hasConflict }

    init(trackWeekly: Bool) { self.trackWeekly = trackWeekly }

    func observe(key: Data, current: TokenUsage, delta: TokenUsage?, continuing: Bool,
                 model: String?, tier: String?, requestInput: Int64?, timestamp: Date, timestampText: String?,
                 today: Bool, inWeeklyWindow: Bool) {
        let sample = Sample(usage: current, timestamp: timestamp, timestampText: timestampText,
                            model: model, tier: tier, requestInput: requestInput)
        daily.observe(key: key, sample: sample, delta: delta, path: path, continuing: continuing, include: today)
        if trackWeekly && isWeeklySource {
            weekly.observe(key: key, sample: sample, delta: delta, path: path, continuing: continuing, include: inWeeklyWindow)
        }
    }

    func resolvedContributions() throws -> [Contribution] {
        try daily.resolve(weekly: false) + weekly.resolve(weekly: true)
    }

    func claimDaily(_ key: Data) -> Bool {
        if let owner = dailyOwners[key] { return owner == path }
        dailyOwners[key] = path
        return true
    }

    static func eventKey(session: String?, activeSession: String?, timestamp: Date?, usage: TokenUsage,
                         model: String?, tier: String?, requestInput: Int64?, imported: Bool) -> Data {
        struct Identity: Encodable {
            let session: String?
            let activeSession: String?
            let timestamp: Date?
            let usage: TokenUsage
            let model: String?
            let tier: String?
            let requestInput: Int64?
            let imported: Bool
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let value = Identity(session: session, activeSession: activeSession, timestamp: timestamp, usage: usage,
                             model: model, tier: tier, requestInput: requestInput, imported: imported)
        return Data(SHA256.hash(data: try! encoder.encode(value)))
    }
}
