import Foundation

/// Owns refresh work and retained data independently of menu drawing and OS events.
@MainActor
public final class UsageRefreshController {
    public private(set) var state = UsageRefreshState()
    public var onChange: (() -> Void)?
    /// The adapter calls completion with nil only after the notification center
    /// accepts the request, or with an error when submission fails.
    public var onQuotaAlert: ((QuotaAlertRequest, @escaping @MainActor @Sendable (String?) -> Void) -> Void)?
    public var onCancelQuotaAlerts: (([String]) -> Void)?
    public var alertsEnabled = false {
        didSet {
            if !alertsEnabled {
                invalidateAlerts()
                state.quotaAlertError = nil
            }
        }
    }

    private let services: UsageRefreshServices
    private let executor: any RefreshExecuting
    private let now: @Sendable () -> Date
    private var coordinator: RefreshCoordinator
    private var operations: [Int: RefreshCancellation] = [:]
    private var suspended = false
    private var stopped = false
    private var activeAlerts: [String: ActiveQuotaAlert] = [:]

    public convenience init() {
        self.init(services: .live(), executor: DispatchRefreshExecutor())
    }

    init(services: UsageRefreshServices, executor: any RefreshExecuting,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.services = services
        self.executor = executor
        self.now = now
        coordinator = RefreshCoordinator(accountIdentity: services.identity())
    }

    deinit { for operation in operations.values { operation.cancel() } }

    public var freshness: RefreshSnapshot { coordinator.snapshot(now: now()) }

    public func refresh() {
        refreshOfficial()
        refreshLocal()
    }

    public func heartbeat() {
        guard !stopped else { return }
        synchronizeAccount()
        expireAlerts()
        for ticket in coordinator.expire(now: now()) { operations[ticket.id]?.cancel() }
        refreshOfficial(reason: .timer)
        refreshLocal(reason: .timer)
        onChange?()
    }

    public func sleep() {
        suspended = true
        invalidateWork()
        onChange?()
    }

    public func wake() {
        suspended = false
        refreshOfficial(reason: .recovery)
        refreshLocal(reason: .recovery)
    }

    public func setNetworkAvailable(_ available: Bool) {
        let restored = coordinator.setNetworkAvailable(available)
        if restored { refreshOfficial(reason: .recovery) }
        onChange?()
    }

    public func stop() {
        stopped = true
        invalidateWork()
    }

    private func invalidateWork() {
        invalidateAlerts()
        for lane in RefreshLane.allCases {
            if let ticket = coordinator.invalidate(lane, now: now()) { operations[ticket.id]?.cancel() }
        }
    }

    private func synchronizeAccount() {
        let identity = services.identity()
        guard identity != coordinator.accountIdentity else { return }
        invalidateAlerts()
        for ticket in coordinator.changeAccount(to: identity, now: now()) { operations[ticket.id]?.cancel() }
        state = UsageRefreshState()
        onChange?()
    }

    public func refreshOfficial(reason: RefreshReason = .manual) {
        guard !stopped else { return }
        synchronizeAccount()
        guard !suspended, let ticket = coordinator.request(.official, reason: reason, now: now()) else { return }
        let cancellation = RefreshCancellation(deadline: ticket.deadline, now: now)
        operations[ticket.id] = cancellation
        let services = services
        let alertsEnabled = alertsEnabled
        onChange?()
        executor.execute(.official) { [weak self] in
            let result = Result { () throws -> (OfficialUsageUpdate, QuotaMonitorSnapshot?) in
                try cancellation.check()
                guard ticket.accountIdentity == services.identity() else { throw RuntimeError("Account changed.") }
                let update = try services.official(cancellation)
                try cancellation.check()
                guard ticket.accountIdentity == services.identity() else { throw RuntimeError("Account changed.") }
                let history = update.weekly.map { services.history($0, alertsEnabled, update.accountContext) }
                return (update, history)
            }
            DispatchQueue.main.async {
                self?.completeOfficial(ticket, result: result)
            }
        }
    }

    private func completeOfficial(_ ticket: RefreshTicket, result: Result<(OfficialUsageUpdate, QuotaMonitorSnapshot?), Error>) {
        synchronizeAccount()
        let outcomes: [RefreshSource: RefreshOutcome]
        let changedContext: Bool
        switch result {
        case .success(let value):
            outcomes = value.0.outcomes
            changedContext = state.accountContext != nil && state.accountContext != value.0.accountContext
        case .failure(let error):
            outcomes = Dictionary(uniqueKeysWithValues: RefreshLane.official.sources.map {
                ($0, RefreshOutcome(.failed, error: Self.normalizedErrorText(error)))
            })
            changedContext = false
        }
        let accepted = coordinator.complete(ticket, outcomes: outcomes, now: now(), resetHistory: changedContext)
        operations.removeValue(forKey: ticket.id)
        if accepted, case .success(let value) = result { applyOfficial(value.0, monitor: value.1) }
        onChange?()
        refreshOfficial(reason: .timer)
    }

    public func refreshLocal(reason: RefreshReason = .manual) {
        guard !stopped else { return }
        synchronizeAccount()
        guard !suspended, let ticket = coordinator.request(.local, reason: reason, now: now()) else { return }
        let cancellation = RefreshCancellation(deadline: ticket.deadline, now: now)
        operations[ticket.id] = cancellation
        let services = services
        let request = LocalUsageRequest(weeklyWindow: state.weeklyWindow, accountContext: state.accountContext,
                                        quotaSampleAt: state.quotaSampleAt, rebuild: ticket.rebuild)
        onChange?()
        executor.execute(.local) { [weak self] in
            let result = Result {
                try cancellation.check()
                guard ticket.accountIdentity == services.identity() else { throw RuntimeError("Account changed.") }
                return try services.local(request, cancellation)
            }
            DispatchQueue.main.async {
                self?.completeLocal(ticket, result: result)
            }
        }
    }

    private func completeLocal(_ ticket: RefreshTicket, result: Result<LocalUsageSnapshot, Error>) {
        synchronizeAccount()
        let outcome: RefreshOutcome
        switch result {
        case .success(let value): outcome = RefreshOutcome.local(value)
        case .failure(let error): outcome = RefreshOutcome(.failed, error: Self.normalizedErrorText(error))
        }
        let accepted = coordinator.complete(ticket, outcomes: [.localUsage: outcome], now: now())
        operations.removeValue(forKey: ticket.id)
        if accepted, outcome.phase != .failed, case .success(let value) = result { state.localUsage = value }
        onChange?()
        refreshLocal(reason: .timer)
    }

    private func applyOfficial(_ update: OfficialUsageUpdate, monitor: QuotaMonitorSnapshot?) {
        guard update.error == nil else { return }
        let previousContext = state.accountContext
        let previousWindow = state.weeklyWindow.flatMap(QuotaWindowID.init)?.rawValue
        let previousSampleAt = state.quotaSampleAt
        if previousContext != update.accountContext {
            invalidateAlerts()
            state.quotaAlertError = nil
            if let ticket = coordinator.invalidate(.local, now: now(), clear: true) { operations[ticket.id]?.cancel() }
            state.localUsage = nil
            state.resetCredits = nil
        }
        state.accountContext = update.accountContext
        state.quotaSampleAt = update.sampledAt
        state.weeklyWindow = update.weekly
        state.credits = update.outcomes[.credits]?.phase == .unavailable ? nil : update.credits
        if update.outcomes[.resetCredits]?.phase != .failed { state.resetCredits = update.resetCredits }
        state.quotaForecast = monitor?.forecast
        state.quotaMonitorError = monitor?.persistenceError
        let alerts = monitor?.alerts ?? []
        cancelAlerts(activeAlerts.filter { _, delivery in
            delivery.request.event.windowID != state.weeklyWindow.flatMap(QuotaWindowID.init)
                || (!delivery.accepted && !alerts.contains { $0.identifier == delivery.request.event.identifier })
        }.map(\.key))
        for alert in alerts { submitAlert(alert) }
        if previousContext != state.accountContext || previousWindow != state.weeklyWindow.flatMap(QuotaWindowID.init)?.rawValue
            || previousSampleAt != state.quotaSampleAt {
            refreshLocal(reason: .quotaChanged)
        }
    }

    private func submitAlert(_ event: QuotaAlertEvent) {
        guard alertsEnabled, !suspended, !stopped, let onQuotaAlert,
              services.identity() == coordinator.accountIdentity,
              event.accountScopeKey == state.accountContext?.scopeKey,
              event.windowID == state.weeklyWindow.flatMap(QuotaWindowID.init),
              (event.expiresAt ?? event.resetAt) > now(),
              !activeAlerts.values.contains(where: { $0.request.event.identifier == event.identifier }) else { return }
        let request = QuotaAlertRequest(event: event, identifier: event.identifier + "-" + UUID().uuidString)
        activeAlerts[request.identifier] = ActiveQuotaAlert(request: request,
            identity: coordinator.accountIdentity, deadline: now().addingTimeInterval(45))
        onQuotaAlert(request) { [weak self] error in
            self?.completeAlert(request, error: error)
        }
    }

    private func completeAlert(_ request: QuotaAlertRequest, error: String?) {
        synchronizeAccount()
        guard var delivery = activeAlerts[request.identifier], !delivery.accepted else {
            // A cancelled add() may finish later. Its unique attempt ID cannot
            // cancel a newer request for the same quota warning.
            if activeAlerts[request.identifier] == nil { onCancelQuotaAlerts?([request.identifier]) }
            return
        }
        guard alertsEnabled, !suspended, !stopped, delivery.deadline > now(),
              delivery.identity == coordinator.accountIdentity,
              request.event.accountScopeKey == state.accountContext?.scopeKey,
              request.event.windowID == state.weeklyWindow.flatMap(QuotaWindowID.init),
              (request.event.expiresAt ?? request.event.resetAt) > now() else {
            cancelAlerts([request.identifier])
            return
        }
        state.quotaAlertError = error
        if error != nil {
            cancelAlerts([request.identifier])
            onChange?()
            return
        }
        delivery.accepted = true
        activeAlerts[request.identifier] = delivery
        let services = services
        let identity = delivery.identity
        executor.execute(.official) { [weak self] in
            guard services.identity() == identity else {
                DispatchQueue.main.async { self?.finishAlertAcknowledgement(request, error: nil) }
                return
            }
            let error = services.acknowledgeAlert(request.event)
            DispatchQueue.main.async { self?.finishAlertAcknowledgement(request, error: error) }
        }
        onChange?()
    }

    private func finishAlertAcknowledgement(_ request: QuotaAlertRequest, error: String?) {
        synchronizeAccount()
        guard activeAlerts.removeValue(forKey: request.identifier) != nil else { return }
        state.quotaMonitorError = error
        onChange?()
    }

    private func expireAlerts() {
        cancelAlerts(activeAlerts.filter { !$0.value.accepted && $0.value.deadline <= now() }.map(\.key))
    }

    private func invalidateAlerts() { cancelAlerts(Array(activeAlerts.keys)) }

    private func cancelAlerts(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        // Accepted requests already belong to the notification center. Removing
        // them while their receipt is being saved could lose a confirmed alert.
        let pending = identifiers.filter { activeAlerts[$0]?.accepted != true }
        for identifier in identifiers { activeAlerts.removeValue(forKey: identifier) }
        if !pending.isEmpty { onCancelQuotaAlerts?(pending) }
    }

    private static func normalizedErrorText(_ error: Error) -> String {
        error.localizedDescription.replacingOccurrences(of: "\t", with: " ")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
