import Foundation

public struct QuotaWindowID: Codable, Equatable, Hashable, Sendable {
    public let durationMinutes: Int
    public let resetAtBucket: Int

    public init?(window: RateLimitWindow) {
        guard let durationMinutes = window.windowDurationMins,
              durationMinutes > 0,
              let resetDate = window.resetDate
        else {
            return nil
        }
        self.durationMinutes = durationMinutes
        resetAtBucket = Int((resetDate.timeIntervalSince1970 / 300).rounded()) * 300
    }

    public var rawValue: String {
        "\(durationMinutes)-\(resetAtBucket)"
    }
}

public struct QuotaSample: Codable, Equatable, Sendable {
    public let windowID: QuotaWindowID
    public let timestamp: Date
    public let usedPercent: Int
    public let remainingPercent: Int

    public init(windowID: QuotaWindowID, timestamp: Date, usedPercent: Int, remainingPercent: Int) {
        self.windowID = windowID
        self.timestamp = timestamp
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
    }
}

public enum QuotaForecastStatus: String, Codable, Sendable {
    case insufficientData
    case onPace
    case atRisk
    case exhausted
}

public enum QuotaForecastBasis: String, Codable, Sendable {
    case windowAverage
    case recentTrend
}

public enum QuotaForecastConfidence: String, Codable, Sendable {
    case low
    case medium
    case high
}

public struct QuotaForecast: Codable, Equatable, Sendable {
    public let windowID: QuotaWindowID
    public let status: QuotaForecastStatus
    public let basis: QuotaForecastBasis
    public let confidence: QuotaForecastConfidence
    public let budgetRemainingPercent: Double
    public let projectedRemainingAtReset: Double?
    public let projectedExhaustionAt: Date?
    public let paceRatio: Double?
    public let consumptionRatePercentPerHour: Double?
}

public enum QuotaForecastEngine {
    public static func forecast(
        window: RateLimitWindow,
        samples: [QuotaSample],
        now: Date = Date()
    ) -> QuotaForecast? {
        guard let windowID = QuotaWindowID(window: window),
              let resetDate = window.resetDate,
              let durationMinutes = window.windowDurationMins,
              durationMinutes > 0
        else {
            return nil
        }

        let duration = TimeInterval(durationMinutes * 60)
        let windowStart = resetDate.addingTimeInterval(-duration)
        let elapsed = max(0, min(duration, now.timeIntervalSince(windowStart)))
        let timeRemaining = max(0, resetDate.timeIntervalSince(now))
        let remaining = Double(max(0, min(100, window.remainingPercent)))
        let used = Double(max(0, min(100, 100 - window.remainingPercent)))
        let budgetRemaining = max(0, min(100, (timeRemaining / duration) * 100))

        if remaining <= 0 {
            return QuotaForecast(
                windowID: windowID,
                status: .exhausted,
                basis: .windowAverage,
                confidence: .high,
                budgetRemainingPercent: budgetRemaining,
                projectedRemainingAtReset: 0,
                projectedExhaustionAt: now,
                paceRatio: nil,
                consumptionRatePercentPerHour: nil
            )
        }

        let averageRate = elapsed >= 30 * 60 && used >= 1 ? used / elapsed : nil
        let recent = recentRate(
            windowID: windowID,
            currentRemaining: remaining,
            samples: samples,
            now: now,
            windowStart: windowStart
        )
        let selectedRate = recent?.rate ?? averageRate
        let basis: QuotaForecastBasis = recent == nil ? .windowAverage : .recentTrend
        let confidence = confidence(
            basis: basis,
            used: used,
            elapsed: elapsed,
            recentDelta: recent?.delta,
            recentInterval: recent?.interval
        )

        guard let rate = selectedRate, rate > 0, timeRemaining > 0 else {
            return QuotaForecast(
                windowID: windowID,
                status: .insufficientData,
                basis: basis,
                confidence: .low,
                budgetRemainingPercent: budgetRemaining,
                projectedRemainingAtReset: nil,
                projectedExhaustionAt: nil,
                paceRatio: nil,
                consumptionRatePercentPerHour: nil
            )
        }

        let projectedRemaining = max(0, remaining - rate * timeRemaining)
        let exhaustionDate = now.addingTimeInterval(remaining / rate)
        let reachesLimitBeforeReset = exhaustionDate < resetDate.addingTimeInterval(-15 * 60)
        let idealRate = 100 / duration

        return QuotaForecast(
            windowID: windowID,
            status: reachesLimitBeforeReset ? .atRisk : .onPace,
            basis: basis,
            confidence: confidence,
            budgetRemainingPercent: budgetRemaining,
            projectedRemainingAtReset: projectedRemaining,
            projectedExhaustionAt: reachesLimitBeforeReset ? exhaustionDate : nil,
            paceRatio: rate / idealRate,
            consumptionRatePercentPerHour: rate * 3600
        )
    }

    private static func recentRate(
        windowID: QuotaWindowID,
        currentRemaining: Double,
        samples: [QuotaSample],
        now: Date,
        windowStart: Date
    ) -> (rate: Double, delta: Double, interval: TimeInterval)? {
        let earliestAllowed = max(windowStart, now.addingTimeInterval(-24 * 60 * 60))
        let candidates = samples.filter {
            $0.windowID == windowID
                && $0.timestamp >= earliestAllowed
                && $0.timestamp <= now.addingTimeInterval(-60 * 60)
                && Double($0.remainingPercent) > currentRemaining
        }
        guard let sample = candidates.min(by: { $0.timestamp < $1.timestamp }) else {
            return nil
        }

        let interval = now.timeIntervalSince(sample.timestamp)
        let delta = Double(sample.remainingPercent) - currentRemaining
        guard interval >= 60 * 60, delta >= 2 else { return nil }
        return (delta / interval, delta, interval)
    }

    private static func confidence(
        basis: QuotaForecastBasis,
        used: Double,
        elapsed: TimeInterval,
        recentDelta: Double?,
        recentInterval: TimeInterval?
    ) -> QuotaForecastConfidence {
        if basis == .recentTrend {
            if (recentDelta ?? 0) >= 5, (recentInterval ?? 0) >= 2 * 60 * 60 {
                return .high
            }
            return .medium
        }
        if used >= 10, elapsed >= 6 * 60 * 60 {
            return .high
        }
        if used >= 3, elapsed >= 60 * 60 {
            return .medium
        }
        return .low
    }
}

public enum QuotaAlertKind: String, Codable, CaseIterable, Sendable {
    case warning
    case critical
    case projectedExhaustion
    case reset
}

public struct QuotaAlertEvent: Codable, Equatable, Sendable {
    public let kind: QuotaAlertKind
    public let windowID: QuotaWindowID
    public let remainingPercent: Int
    public let resetAt: Date
    public let projectedExhaustionAt: Date?

    public var accountScopeKey: String? = nil
    // Persist the decision's coverage; a later forecast must not change what an
    // already submitted notification acknowledges.
    var coveredKinds: Set<QuotaAlertKind>? = nil
    var expiresAt: Date? = nil

    public var identifier: String {
        "quota-\(accountScopeKey.map { $0 + "-" } ?? "")\(windowID.rawValue)-\(kind.rawValue)"
    }
}

public struct QuotaAlertState: Codable, Equatable, Sendable {
    public var windowID: QuotaWindowID?
    public var resetAt: Date?
    public var deliveredKinds: Set<QuotaAlertKind>
    public var lastRemainingPercent: Int?
    var pendingAlert: QuotaAlertEvent?

    public init(
        windowID: QuotaWindowID? = nil,
        resetAt: Date? = nil,
        deliveredKinds: Set<QuotaAlertKind> = [],
        lastRemainingPercent: Int? = nil
    ) {
        self.windowID = windowID
        self.resetAt = resetAt
        self.deliveredKinds = deliveredKinds
        self.lastRemainingPercent = lastRemainingPercent
    }

    mutating func acknowledge(_ event: QuotaAlertEvent) {
        guard windowID == event.windowID else { return }
        deliveredKinds.formUnion(event.coveredKinds ?? [event.kind])
        if pendingAlert?.kind == event.kind { pendingAlert = nil }
    }
}

public struct QuotaAlertDecision: Equatable, Sendable {
    public let events: [QuotaAlertEvent]
    public let state: QuotaAlertState
}

public enum QuotaAlertEvaluator {
    public static func evaluate(
        window: RateLimitWindow,
        forecast: QuotaForecast?,
        previousState: QuotaAlertState,
        alertsEnabled: Bool,
        now: Date = Date()
    ) -> QuotaAlertDecision {
        guard let windowID = QuotaWindowID(window: window),
              let resetAt = window.resetDate
        else {
            return QuotaAlertDecision(events: [], state: previousState)
        }

        var state = previousState
        var resetExpiry = state.pendingAlert.flatMap { $0.kind == .reset ? $0.expiresAt : nil }
        if state.windowID != windowID {
            let previousResetAt = state.resetAt
            let minimumNewWindowAdvance = TimeInterval(windowID.durationMinutes * 60) * 0.5
            let looksLikeNewWindow = previousResetAt.map {
                resetAt.timeIntervalSince($0) >= minimumNewWindowAdvance
            } ?? false
            let isPlausibleReset = previousResetAt.map {
                looksLikeNewWindow
                    && $0 >= now.addingTimeInterval(-15 * 60)
                    && $0 <= now.addingTimeInterval(5 * 60)
            } ?? false
            let shouldPreserveDeliveredKinds = previousResetAt != nil && !looksLikeNewWindow

            state.windowID = windowID
            state.resetAt = resetAt
            state.lastRemainingPercent = nil
            if !shouldPreserveDeliveredKinds {
                state.deliveredKinds = []
                resetExpiry = nil
            }

            if alertsEnabled, previousState.windowID != nil, isPlausibleReset {
                resetExpiry = previousResetAt?.addingTimeInterval(15 * 60)
            }
        } else {
            state.resetAt = resetAt
        }

        let remaining = max(0, min(100, window.remainingPercent))
        state.lastRemainingPercent = remaining
        state.pendingAlert = nil
        if let resetExpiry, resetExpiry > now, !state.deliveredKinds.contains(.reset) {
            var reset = event(kind: .reset, window: window, windowID: windowID, forecast: forecast)
            reset.expiresAt = resetExpiry
            state.pendingAlert = reset
        }
        guard alertsEnabled else {
            return QuotaAlertDecision(events: [], state: state)
        }
        if let pending = state.pendingAlert {
            return QuotaAlertDecision(events: [pending], state: state)
        }
        guard resetAt > now else {
            return QuotaAlertDecision(events: [], state: state)
        }

        let forecastIsActionable = forecast?.status == .atRisk
            && forecast?.confidence != .low
            && forecast?.projectedExhaustionAt != nil

        let kind: QuotaAlertKind?
        if remaining <= 10, !state.deliveredKinds.contains(.critical) {
            kind = .critical
        } else if remaining <= 25, !state.deliveredKinds.contains(.warning) {
            kind = .warning
        } else if forecastIsActionable, !state.deliveredKinds.contains(.projectedExhaustion) {
            kind = .projectedExhaustion
        } else {
            kind = nil
        }
        if let kind {
            var pending = event(kind: kind, window: window, windowID: windowID, forecast: forecast)
            var covered: Set<QuotaAlertKind> = [kind]
            if kind == .critical { covered.insert(.warning) }
            if forecastIsActionable { covered.insert(.projectedExhaustion) }
            pending.coveredKinds = covered
            pending.expiresAt = resetAt
            state.pendingAlert = pending
        }
        return QuotaAlertDecision(events: state.pendingAlert.map { [$0] } ?? [], state: state)
    }

    private static func event(
        kind: QuotaAlertKind,
        window: RateLimitWindow,
        windowID: QuotaWindowID,
        forecast: QuotaForecast?
    ) -> QuotaAlertEvent {
        QuotaAlertEvent(
            kind: kind,
            windowID: windowID,
            remainingPercent: max(0, min(100, window.remainingPercent)),
            resetAt: window.resetDate ?? Date(),
            projectedExhaustionAt: forecast?.projectedExhaustionAt
        )
    }
}

public struct QuotaMonitorSnapshot: Sendable {
    public let forecast: QuotaForecast?
    public let alerts: [QuotaAlertEvent]
    public let sampleCount: Int
    public let persistenceError: String?
}

public final class QuotaMonitor: @unchecked Sendable {
    private struct Document: Codable {
        var version = 1
        var samples: [QuotaSample] = []
        var alertState = QuotaAlertState()
        var accountScopeKey: String?
    }

    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Codex Rate Limits Bar")
            .appendingPathComponent("quota-history.json")
    }

    private let baseFileURL: URL
    private var fileURL: URL
    private var activeScopeKey: String?
    private let lock = NSLock()
    private var isLoaded = false
    private var isDirty = false
    private var document = Document()

    public init(fileURL: URL = QuotaMonitor.defaultFileURL) {
        self.baseFileURL = fileURL
        self.fileURL = fileURL
    }

    public func update(
        window: RateLimitWindow,
        at now: Date = Date(),
        alertsEnabled: Bool,
        accountContext: CodexAccountContext? = nil
    ) -> QuotaMonitorSnapshot {
        lock.lock()
        defer { lock.unlock() }
        if let accountContext, accountContext.scopeKey == nil {
            return QuotaMonitorSnapshot(forecast: nil, alerts: [], sampleCount: 0, persistenceError: nil)
        }
        let scope = accountContext?.scopeKey
        if activeScopeKey != scope {
            activeScopeKey = scope
            fileURL = scope.map {
                baseFileURL.deletingPathExtension().appendingPathExtension($0 + ".json")
            } ?? baseFileURL
            document = Document(accountScopeKey: scope)
            isLoaded = false
            isDirty = false
        }
        loadIfNeeded()

        guard let windowID = QuotaWindowID(window: window) else {
            return QuotaMonitorSnapshot(forecast: nil, alerts: [], sampleCount: 0, persistenceError: nil)
        }

        reconcileShiftedActiveWindow(to: windowID, resetAt: window.resetDate)
        let sample = QuotaSample(
            windowID: windowID,
            timestamp: now,
            usedPercent: max(0, min(100, window.usedPercent)),
            remainingPercent: max(0, min(100, window.remainingPercent))
        )
        if shouldAppend(sample) {
            document.samples.append(sample)
            pruneSamples(relativeTo: now)
            isDirty = true
        }

        let windowSamples = document.samples.filter { $0.windowID == windowID }
        let forecast = QuotaForecastEngine.forecast(window: window, samples: windowSamples, now: now)
        let decision = QuotaAlertEvaluator.evaluate(
            window: window,
            forecast: forecast,
            previousState: document.alertState,
            alertsEnabled: alertsEnabled,
            now: now
        )
        if decision.state != document.alertState {
            document.alertState = decision.state
            isDirty = true
        }

        let persistenceError = persistIfNeeded()

        let alerts = decision.events.map { event in
            var scoped = event
            scoped.accountScopeKey = activeScopeKey
            return scoped
        }
        return QuotaMonitorSnapshot(
            forecast: forecast,
            alerts: alerts,
            sampleCount: windowSamples.count,
            persistenceError: persistenceError
        )
    }

    /// Confirmation means the notification center accepted the request, not
    /// that the user saw it. Rejected/cancelled requests never call this method.
    func acknowledge(_ event: QuotaAlertEvent) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard isLoaded, activeScopeKey == event.accountScopeKey,
              document.alertState.windowID == event.windowID else { return nil }
        document.alertState.acknowledge(event)
        isDirty = true
        return persistIfNeeded()
    }

    private func persistIfNeeded() -> String? {
        guard isDirty else { return nil }
        do {
            try save()
            isDirty = false
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func reconcileShiftedActiveWindow(to windowID: QuotaWindowID, resetAt: Date?) {
        guard let previousID = document.alertState.windowID,
              previousID != windowID,
              let previousResetAt = document.alertState.resetAt,
              let resetAt,
              abs(resetAt.timeIntervalSince(previousResetAt)) < TimeInterval(windowID.durationMinutes * 60) * 0.5
        else {
            return
        }

        var changed = false
        document.samples = document.samples.map { sample in
            guard sample.windowID == previousID else { return sample }
            changed = true
            return QuotaSample(
                windowID: windowID,
                timestamp: sample.timestamp,
                usedPercent: sample.usedPercent,
                remainingPercent: sample.remainingPercent
            )
        }
        if changed {
            isDirty = true
        }
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let loaded = try? decoder.decode(Document.self, from: data),
           loaded.accountScopeKey == activeScopeKey {
            document = loaded
        }
    }

    private func shouldAppend(_ sample: QuotaSample) -> Bool {
        guard let previous = document.samples.last(where: { $0.windowID == sample.windowID }) else {
            return true
        }
        return previous.usedPercent != sample.usedPercent
            || previous.remainingPercent != sample.remainingPercent
            || sample.timestamp.timeIntervalSince(previous.timestamp) >= 30 * 60
    }

    private func pruneSamples(relativeTo now: Date) {
        let cutoff = now.addingTimeInterval(-60 * 24 * 60 * 60)
        document.samples.removeAll { $0.timestamp < cutoff }
        if document.samples.count > 2_000 {
            document.samples = Array(document.samples.suffix(2_000))
        }
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try (data + Data("\n".utf8)).write(to: fileURL, options: .atomic)
    }
}
