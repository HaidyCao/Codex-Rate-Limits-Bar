import Foundation

public enum RefreshSource: String, Codable, CaseIterable, Sendable {
    case quota, credits, resetCredits, localUsage
    public var maximumAge: TimeInterval { self == .localUsage ? 120 : 300 }
}

public enum RefreshPhase: String, Codable, Sendable {
    case idle, refreshing, success, partial, failed, unavailable, stale
}

public struct DataFreshness: Codable, Sendable {
    public let status: RefreshPhase
    public let lastAttemptAtIso: String?
    public let lastSuccessAtIso: String?
    public let dataAtIso: String?
    public let ageSeconds: Double?
    public let isStale: Bool
    public let error: String?
    public let nextRetryAtIso: String?
}

public struct RefreshSnapshot: Codable, Sendable {
    public let quota: DataFreshness
    public let credits: DataFreshness
    public let resetCredits: DataFreshness
    public let localUsage: DataFreshness
    public let networkAvailable: Bool?

    public subscript(_ source: RefreshSource) -> DataFreshness {
        switch source {
        case .quota: quota
        case .credits: credits
        case .resetCredits: resetCredits
        case .localUsage: localUsage
        }
    }
}

public struct RefreshOutcome: Sendable {
    public let phase: RefreshPhase
    public let sampledAt: Date?
    public let error: String?

    public init(_ phase: RefreshPhase, at sampledAt: Date? = nil, error: String? = nil) {
        self.phase = phase; self.sampledAt = sampledAt; self.error = error
    }

    public static func official(_ payload: RateLimitPayload) -> [RefreshSource: RefreshOutcome] {
        let at = date(payload.fetchedAtIso)
        if let error = payload.rateLimitError {
            return Dictionary(uniqueKeysWithValues: RefreshLane.official.sources.map { ($0, RefreshOutcome(.failed, error: error)) })
        }
        let quota = payload.selectedRateLimit?.weeklyWindow
        let credits = payload.selectedRateLimit?.credits
        let hasBalance = credits?.unlimited == true || credits?.balance.flatMap(Double.init)?.isFinite == true
        let reset = payload.resetCredits
        return [
            .quota: RefreshOutcome(quota == nil ? .unavailable : .success, at: quota == nil ? nil : at,
                                   error: quota == nil ? "Weekly quota was not returned." : nil),
            .credits: RefreshOutcome(hasBalance ? .success : .unavailable, at: hasBalance ? at : nil,
                                     error: hasBalance ? nil : "Credit balance was not returned."),
            .resetCredits: RefreshOutcome(reset?.error != nil ? .failed : reset?.availableCount == nil ? .unavailable
                : reset?.detailsAvailable == false ? .partial : .success,
                at: reset?.error == nil && reset?.availableCount != nil ? date(reset?.fetchedAtIso) : nil,
                error: reset?.error ?? (reset?.availableCount == nil ? "Reset-credit count was not returned." : nil))
        ]
    }

    public static func local(_ usage: LocalUsageSnapshot) -> RefreshOutcome {
        let phase: RefreshPhase = usage.diagnostics?.status == .unavailable ? .failed
            : usage.error != nil || usage.diagnostics?.status == .partial ? .partial : .success
        return RefreshOutcome(phase, at: phase == .failed ? nil : date(usage.fetchedAtIso), error: usage.error)
    }

    public static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

public enum RefreshLane: String, CaseIterable, Sendable {
    case official, local
    public var sources: [RefreshSource] { self == .official ? [.quota, .credits, .resetCredits] : [.localUsage] }
    public var interval: TimeInterval { self == .official ? 60 : 30 }
    public var timeout: TimeInterval { self == .official ? 45 : 180 }
}

public enum RefreshReason: Sendable {
    case timer, manual, recovery, quotaChanged, rebuild
    var bypassesBackoff: Bool { self == .manual || self == .recovery || self == .rebuild }
}

public struct RefreshTicket: Equatable, Sendable {
    public let id: Int
    public let lane: RefreshLane
    public let accountIdentity: String
    public let generation: Int
    public let startedAt: Date
    public let deadline: Date
    public let rebuild: Bool
}

/// Main-thread value state, also used by deterministic tests. At most one
/// worker and one coalesced follow-up exist per lane, including after timeout.
public struct RefreshCoordinator {
    private struct SourceState {
        var phase: RefreshPhase = .idle
        var attempted: Date?
        var succeeded: Date?
        var dataAt: Date?
        var error: String?

        mutating func apply(_ outcome: RefreshOutcome) {
            phase = outcome.phase
            error = outcome.error
            switch outcome.phase {
            case .success, .partial:
                dataAt = outcome.sampledAt
                if outcome.phase == .success || outcome.error == nil { succeeded = outcome.sampledAt }
            case .unavailable: dataAt = nil
            default: break // A failure must not date old data as a new success.
            }
        }

        func snapshot(_ source: RefreshSource, now: Date, retry: Date?) -> DataFreshness {
            let formatter = ISO8601DateFormatter()
            let age = dataAt.map { max(0, now.timeIntervalSince($0)) }
            let stale = dataAt.map { now.timeIntervalSince($0) > source.maximumAge || $0 > now.addingTimeInterval(5) } ?? false
            return DataFreshness(status: stale && phase == .success ? .stale : phase,
                lastAttemptAtIso: attempted.map(formatter.string), lastSuccessAtIso: succeeded.map(formatter.string),
                dataAtIso: dataAt.map(formatter.string), ageSeconds: age, isStale: stale, error: error,
                nextRetryAtIso: retry.map(formatter.string))
        }
    }
    private struct LaneState {
        var active: RefreshTicket?
        var invalidated = false
        var pending = false
        var pendingForced = false
        var pendingRebuild = false
        var failures = 0
        var due = Date.distantPast
        var generation = 0
    }
    private var sources: [RefreshSource: SourceState] = [:]
    private var lanes: [RefreshLane: LaneState] = [:]
    private var nextID = 0
    public private(set) var accountIdentity: String
    public private(set) var networkAvailable: Bool?

    public init(accountIdentity: String) { self.accountIdentity = accountIdentity }

    public mutating func changeAccount(to identity: String, now: Date) -> [RefreshTicket] {
        guard accountIdentity != identity else { return [] }
        accountIdentity = identity
        sources = [:]
        return RefreshLane.allCases.compactMap { lane in invalidate(lane, now: now, clear: true) }
    }

    @discardableResult
    public mutating func invalidate(_ lane: RefreshLane, now: Date, clear: Bool = false) -> RefreshTicket? {
        var state = lanes[lane] ?? LaneState()
        state.generation += 1
        state.pendingRebuild = state.pendingRebuild || state.active?.rebuild == true
        state.invalidated = true
        state.pending = true
        state.pendingForced = true
        state.due = now
        if clear { state.failures = 0 }
        for source in lane.sources {
            if clear { sources[source] = SourceState() }
            else if sources[source]?.phase == .refreshing { sources[source]?.phase = .idle }
        }
        lanes[lane] = state
        return state.active
    }

    public mutating func setNetworkAvailable(_ available: Bool) -> Bool {
        let restored = networkAvailable == false && available
        networkAvailable = available
        return restored
    }

    public mutating func request(_ lane: RefreshLane, reason: RefreshReason, now: Date) -> RefreshTicket? {
        var state = lanes[lane] ?? LaneState()
        state.pendingRebuild = state.pendingRebuild || reason == .rebuild
        if reason != .timer { state.pending = true; state.pendingForced = state.pendingForced || reason.bypassesBackoff }
        guard state.active == nil, lane != .official || networkAvailable != false else { lanes[lane] = state; return nil }
        let canRunEarly = state.pendingForced || (state.pending && state.failures == 0)
        guard canRunEarly || now >= state.due else { lanes[lane] = state; return nil }
        nextID += 1
        let ticket = RefreshTicket(id: nextID, lane: lane, accountIdentity: accountIdentity, generation: state.generation,
                                  startedAt: now, deadline: now.addingTimeInterval(lane.timeout), rebuild: state.pendingRebuild)
        state.active = ticket
        state.invalidated = false
        state.pending = false; state.pendingForced = false; state.pendingRebuild = false
        lanes[lane] = state
        for source in lane.sources {
            var value = sources[source] ?? SourceState()
            value.phase = .refreshing
            value.attempted = now
            sources[source] = value
        }
        return ticket
    }

    public func accepts(_ ticket: RefreshTicket) -> Bool {
        guard let state = lanes[ticket.lane] else { return false }
        return state.active?.id == ticket.id && !state.invalidated && state.generation == ticket.generation
            && accountIdentity == ticket.accountIdentity
    }

    /// Releases the physical worker even when its result has been invalidated.
    /// A stale completion cannot release a newer worker or clear its errors.
    @discardableResult
    public mutating func complete(_ ticket: RefreshTicket, outcomes: [RefreshSource: RefreshOutcome], now: Date, resetHistory: Bool = false) -> Bool {
        guard var state = lanes[ticket.lane], state.active?.id == ticket.id else { return false }
        let accepted = accepts(ticket) && now <= ticket.deadline
        if !accepted && !state.invalidated && now > ticket.deadline {
            fail(&state, lane: ticket.lane, error: "Refresh timed out.", now: now)
        }
        state.active = nil
        if accepted {
            var failed = false
            var usefulOfficialData = false
            for source in ticket.lane.sources {
                if resetHistory { sources[source] = SourceState(attempted: ticket.startedAt) }
                let outcome = outcomes[source] ?? RefreshOutcome(.failed, error: "Refresh returned no result.")
                sources[source, default: SourceState()].apply(outcome)
                failed = failed || outcome.phase == .failed || outcome.phase == .unavailable || outcome.error != nil
                usefulOfficialData = usefulOfficialData || outcome.phase == .success || outcome.phase == .partial
            }
            // A failed optional field must not make healthy official data stale.
            // The shared endpoint keeps its regular cadence while any field is usable.
            state.failures = failed && (ticket.lane == .local || !usefulOfficialData) ? min(10, state.failures + 1) : 0
            state.due = now.addingTimeInterval(delay(ticket.lane, failures: state.failures))
        }
        lanes[ticket.lane] = state
        return accepted
    }

    public mutating func expire(now: Date) -> [RefreshTicket] {
        var expired: [RefreshTicket] = []
        for lane in RefreshLane.allCases {
            guard var state = lanes[lane], let ticket = state.active, !state.invalidated, now > ticket.deadline else { continue }
            state.invalidated = true
            fail(&state, lane: lane, error: "Refresh timed out.", now: now)
            lanes[lane] = state
            expired.append(ticket)
        }
        return expired
    }

    private mutating func fail(_ state: inout LaneState, lane: RefreshLane, error: String, now: Date) {
        state.failures = min(10, state.failures + 1)
        state.due = now.addingTimeInterval(delay(lane, failures: state.failures))
        for source in lane.sources { sources[source, default: SourceState()].apply(RefreshOutcome(.failed, error: error)) }
    }

    private func delay(_ lane: RefreshLane, failures: Int) -> TimeInterval {
        failures == 0 ? lane.interval : min(600, lane.interval * pow(2, Double(failures - 1)))
    }

    public func snapshot(now: Date) -> RefreshSnapshot {
        func value(_ source: RefreshSource) -> DataFreshness {
            let lane = lanes[source == .localUsage ? .local : .official]
            return (sources[source] ?? SourceState()).snapshot(source, now: now,
                retry: sources[source]?.error != nil && lane?.active == nil ? lane?.due : nil)
        }
        return RefreshSnapshot(quota: value(.quota), credits: value(.credits), resetCredits: value(.resetCredits),
                               localUsage: value(.localUsage), networkAvailable: networkAvailable)
    }

    public static func oneShot(_ outcomes: [RefreshSource: RefreshOutcome], attemptedAt: Date, now: Date) -> RefreshSnapshot {
        var coordinator = RefreshCoordinator(accountIdentity: "one-shot")
        for (source, outcome) in outcomes {
            var state = SourceState(attempted: attemptedAt)
            state.apply(outcome)
            coordinator.sources[source] = state
        }
        return coordinator.snapshot(now: now)
    }
}

public final class RefreshCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let deadline: Date
    private let now: @Sendable () -> Date

    public convenience init(deadline: Date) { self.init(deadline: deadline, now: Date.init) }
    init(deadline: Date, now: @escaping @Sendable () -> Date) { self.deadline = deadline; self.now = now }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public func check() throws {
        lock.lock(); let cancelled = cancelled; lock.unlock()
        if cancelled { throw RuntimeError("Refresh cancelled.") }
        if now() > deadline { throw RuntimeError("Refresh timed out.") }
    }
}

enum RefreshWork {
    @TaskLocal static var cancellation: RefreshCancellation?
    static func check() throws { try cancellation?.check() }
    static func wait(_ semaphore: DispatchSemaphore, timeout: TimeInterval) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            try check()
            if semaphore.wait(timeout: .now() + min(0.05, max(0, deadline.timeIntervalSinceNow))) == .success { return true }
        } while Date() < deadline
        return false
    }
}
