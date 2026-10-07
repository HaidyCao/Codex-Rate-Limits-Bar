import AppKit
import CodexRateLimitsCore
import Foundation

@main struct VerifyMenu {
    @MainActor static func main() {
        do { try verify() }
        catch {
            try? FileHandle.standardError.write(contentsOf: Data("AppKit verification failed: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor private static func verify() throws {
        guard CommandLine.arguments.count >= 3 else { throw RuntimeError("usage: VerifyMenu FIXTURES OUTPUT [-AppleLanguages (LANG)] [--localized]") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var scenarios = 0
        let pricingAmounts: [String: (api: Double, credits: Double)] = [
            "gpt61-standard": (0.098, 2.45), "gpt61-fast": (0.098, 4.90),
            "sol-fast": (0.106, 5.30), "astra-ultrafast": (0.53, 79.50)
        ]
        let localized = CommandLine.arguments.contains("--localized")
        let contractNames = ["contract-observed", "contract-modes", "contract-pro-no-five-hour", "contract-weekly-only",
                             "contract-credits-only", "contract-api-key", "contract-unknown-plan", "contract-codex-map", "contract-api-key-error"]
        let names = localized ? ["pricing-reasons", "pricing-config-error", "credit-writes"]
            : ["complete", "unknown", "missing-breakdown", "weekly-breakdown", "missing-percent", "invalid-numbers", "partial", "unavailable", "failure", "cache-pending", "partial-cache-pending", "unsupported-mode", "credit-writes", "credit-long-context", "cyber-long-context", "pricing-reasons", "pricing-config-error"] + pricingAmounts.keys.sorted() + contractNames
        for name in names {
            var data = try Data(contentsOf: fixtures.appendingPathComponent("\(name).json"))
            if localized {
                // Older snapshots can omit display strings; render fallbacks in
                // the current process locale while keeping all raw counters.
                var object = try withoutDisplayText(JSONSerialization.jsonObject(with: data)) as! [String: Any]
                // Reset-coupon views consume server-normalized display labels.
                // Re-localize this known fixture rather than dropping its count.
                if var reset = object["resetCredits"] as? [String: Any] {
                    try require(reset["availableCount"] as? Int == 3 && reset["detailsAvailable"] as? Bool == false,
                                "Unexpected localized reset-coupon fixture")
                    reset["display"] = ["summaryLabel": AppText.availableCount(3),
                                        "detailLabels": [AppText.resetCreditDetailsUnavailable]]
                    object["resetCredits"] = reset
                }
                data = try JSONSerialization.data(withJSONObject: object)
            }
            let payload = try JSONDecoder().decode(RateLimitPayload.self, from: data)
            guard let local = payload.localUsage, let freshness = payload.refresh else { throw RuntimeError("Missing shared snapshot: \(name)") }
            // Independent fixture expectations supplement GUI/CLI/MCP parity.
            if name == "complete" {
                try require(local.totalTokens == 1000 && local.todayCost?.estimatedCostUSD == 0.004 && local.todayCredits?.estimatedCredits == 0.1, "Unexpected fixture amounts")
            }
            if let expected = pricingAmounts[name] {
                try require(local.totalTokens == 105_000
                            && abs((local.todayCost?.estimatedCostUSD ?? -1) - expected.api) < 1e-12
                            && abs((local.todayCredits?.estimatedCredits ?? -1) - expected.credits) < 1e-12
                            && local.unpricedUsage?.isEmpty == true, "Unexpected current-rate amounts: \(name)")
            }
            if name.hasPrefix("contract-") {
                let observed = name == "contract-observed"
                try require(local.totalTokens == (observed ? 245_087 : 735_000)
                            && abs((local.todayCost?.estimatedCostUSD ?? -1) - (observed ? 0.30183598 : 0.9353)) < 1e-12
                            && abs((local.todayCredits?.estimatedCredits ?? -1) - (observed ? 7.5458995 : 92.415)) < 1e-12,
                            "Client contract lost independent local amounts: \(name)")
                try require(local.billingAssumptions?.missingServiceTierTokens == (observed ? 245_087 : 105_000)
                            && local.todayCost?.unpricedTokens == (observed ? 0 : 105_000)
                            && local.todayCredits?.unpricedTokens == (observed ? 0 : 210_000),
                            "Client contract lost assumptions or unpriced coverage: \(name)")
                if ["contract-credits-only", "contract-api-key", "contract-unknown-plan", "contract-api-key-error"].contains(name) {
                    try require(payload.selectedRateLimit?.weeklyWindow == nil && local.weeklyQuotaCost == nil,
                                "A plan name invented a weekly quota: \(name)")
                    try require(freshness.quota.status == (name == "contract-api-key-error" ? .failed : .unavailable),
                                "Unavailable and failed quota were conflated: \(name)")
                    try require(local.display?.weeklyQuotaCostLabel == nil
                                && AppText.weeklyQuotaEstimatedCost(nil) == "Weekly quota value unavailable",
                                "Missing weekly data was presented as an active calculation: \(name)")
                }
                if name == "contract-pro-no-five-hour" {
                    try require(payload.selectedRateLimit?.primary == nil
                                && payload.selectedRateLimit?.weeklyWindow?.remainingPercent == 70,
                                "Pro's absent short window changed the returned weekly quota")
                }
                if name == "contract-credits-only" {
                    try require(payload.selectedRateLimit?.credits?.balance == "0" && freshness.credits.status == .success,
                                "Confirmed zero balance became unavailable")
                }
            }
            let rate = RateLimitsMenuView(frame: NSRect(x: 0, y: 0, width: 440, height: 220))
            let reset = ResetCreditsMenuView(frame: NSRect(x: 0, y: 0, width: 440, height: 90))
            let usage = LocalUsageMenuView(frame: NSRect(x: 0, y: 0, width: 440, height: 398))
            rate.update(weekly: payload.selectedRateLimit?.weeklyWindow, forecast: nil,
                        weeklyQuotaCost: local.weeklyQuotaCost, credits: payload.selectedRateLimit?.credits, freshness: freshness)
            reset.update(payload.resetCredits, freshness: freshness.resetCredits)
            usage.update(local, freshness: freshness.localUsage)
            let localText = tooltips(usage)
            try require(localText.contains(AppText.pricingBasisDetails), "GUI lost valuation basis/scope: \(name)")
            if let summary = AppText.unpricedSummary(local.unpricedUsage) {
                try require(localText.contains(summary), "GUI lost the unpriced summary")
                let width = (summary as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10.5)]).width
                try require(width <= 384, "Unpriced summary truncates: \(summary)")
            }
            for label in [local.display?.estimatedCreditsLabel, local.display?.scanStatusLabel] {
                if let label { try require(localText.contains(label), "GUI lost a shared local display label: \(name): \(label)") }
            }
            if name == "unknown" { try require(localText.contains("Raw-Private-Model"), "GUI lost the raw unknown model") }
            if name == "pricing-reasons" || name == "pricing-config-error" {
                try require(local.totalTokens == 1000 && local.todayCost?.coveragePercent == 90
                            && local.todayCredits?.coveragePercent == 40, "GUI mixed independent valuation coverage")
                try require(localText.contains("ultrafast") && localText.contains("300 tokens (30.00%)")
                            && localText.contains(AppText.unpricedReason("unverifiedCacheWrite")), "GUI lost reason details")
                if name == "pricing-config-error" {
                    try require(localText.contains(AppText.pricingConfigurationWarning)
                                && localText.contains(AppText.scanStatus(local.diagnostics)), "Configuration and read errors were conflated")
                }
            }
            if name == "unsupported-mode" {
                try require(local.todayCost?.coveragePercent == 100 && local.todayCredits?.coveragePercent == 0,
                            "Unsupported credit mode changed API coverage")
                try require(localText.contains("ultrafast") && localText.contains("gpt-6.1-sol"),
                            "GUI lost the unsupported model/mode details")
            }
            if name == "missing-breakdown" {
                try require(local.todayCost?.estimatedCostUSD == nil && local.todayCredits?.estimatedCredits == nil,
                            "Incomplete token breakdown became free usage")
                try require(localText.contains(AppText.unpricedUsageDetails(local.unpricedUsage) ?? "missing details"),
                            "GUI lost incomplete-breakdown details")
            }
            if ["credit-writes", "credit-long-context", "cyber-long-context"].contains(name) {
                try require(local.todayCost?.coveragePercent == 100 && local.todayCredits?.estimatedCredits == nil,
                            "Unverified credits changed API coverage or became zero cost")
                let reason = name == "credit-long-context" ? "unsupportedContext" : "unverifiedCacheWrite"
                try require(local.unpricedUsage?.first?.reason == reason
                            && localText.contains(AppText.unpricedUsageDetails(local.unpricedUsage) ?? "missing details"),
                            "GUI lost the unverified credit accounting reason")
            }
            if name == "cyber-long-context" {
                try require(local.totalTokens == 277_001
                            && abs((local.todayCost?.estimatedCostUSD ?? -1) - 5.687525) < 1e-12
                            && local.todayCost?.unpricedTokens == 0
                            && local.todayCredits?.unpricedTokens == 277_001
                            && localText.contains("gpt-daybreak-red-latest"),
                            "GUI lost the Cyber long-context estimate or historical alias")
            }
            if name == "weekly-breakdown" {
                try require(local.weeklyQuotaCost?.valuation?.reason == "incompleteTokenBreakdown",
                            "Weekly pause lost its actual reason")
                try require(tooltips(rate).contains(AppText.incompleteTokenBreakdown),
                            "Weekly GUI mislabels incomplete counters as unknown API prices")
            }
            if name == "missing-percent" || name == "invalid-numbers" {
                try require(payload.selectedRateLimit?.weeklyWindow == nil && freshness.quota.status == .unavailable,
                            "Invalid percentage became a valid quota")
            }
            if name.contains("cache-pending") {
                guard let persistence = local.persistence else { throw RuntimeError("Missing cache persistence") }
                try require(persistence.status == .pending && localText.contains(AppText.cachePersistence(persistence)),
                            "GUI lost the pending cache warning")
                try require(localText.contains(persistence.error ?? "missing cache error"), "GUI lost the cache write error")
                try require(local.totalTokens == 1000 && local.todayCost?.estimatedCostUSD == 0.004,
                            "Cache failure invalidated verified amounts")
                let textWidth = (AppText.localScanStatus(local) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium)]).width
                try require(textWidth <= 416, "Cache warning is clipped in the local status row")
            }
            try require(tooltips(rate).contains(AppText.officialCreditsBalance(payload.selectedRateLimit?.credits)), "GUI balance differs from payload")
            try require(tooltips(rate).contains(AppText.freshnessDetails(freshness.quota, source: .quota)), "GUI lost quota freshness")
            try require(tooltips(reset).contains(AppText.freshnessDetails(freshness.resetCredits, source: .resetCredits)), "GUI lost reset freshness")
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: rate.frame.height + reset.frame.height + usage.frame.height))
            usage.frame.origin = .zero
            reset.frame.origin = NSPoint(x: 0, y: usage.frame.height)
            rate.frame.origin = NSPoint(x: 0, y: usage.frame.height + reset.frame.height)
            for view in [rate, reset, usage] { root.addSubview(view) }
            try render(root, name: name, output: output)
            scenarios += 1
            if name == "complete" {
                // Replay the GUI's retained-data state after a failed refresh.
                let at = Date()
                var coordinator = RefreshCoordinator(accountIdentity: "fixture")
                for lane in RefreshLane.allCases {
                    let ticket = coordinator.request(lane, reason: .manual, now: at)!
                    coordinator.complete(ticket, outcomes: Dictionary(uniqueKeysWithValues: lane.sources.map { ($0, RefreshOutcome(.success, at: at)) }), now: at)
                    let failed = coordinator.request(lane, reason: .manual, now: at)!
                    coordinator.complete(failed, outcomes: Dictionary(uniqueKeysWithValues: lane.sources.map { ($0, RefreshOutcome(.failed, error: "Fixture offline")) }), now: at)
                }
                let stale = coordinator.snapshot(now: at.addingTimeInterval(601))
                rate.update(weekly: payload.selectedRateLimit?.weeklyWindow, forecast: nil, weeklyQuotaCost: nil,
                            credits: payload.selectedRateLimit?.credits, freshness: stale)
                reset.update(payload.resetCredits, freshness: stale.resetCredits)
                usage.update(local, freshness: stale.localUsage)
                try require(tooltips(rate).contains("Fixture offline") && tooltips(usage).contains("Fixture offline"), "Retained-data failure disappeared")
                try render(root, name: "stale", output: output)
                // Account clearing must accept nil data in every view.
                let idle = RefreshCoordinator(accountIdentity: "new-account").snapshot(now: at)
                rate.update(weekly: nil, forecast: nil, weeklyQuotaCost: nil, credits: nil, freshness: idle)
                reset.update(nil, freshness: idle.resetCredits)
                usage.update(nil, freshness: idle.localUsage)
                try require(!tooltips(usage).contains(local.display?.estimatedCreditsLabel ?? "nonexistent"), "Old account amount survived clearing")
                try require(!tooltips(rate).contains("12.5"), "Old account balance survived clearing")
                try render(root, name: "cleared", output: output)
                scenarios += 2
            }
        }
        print("AppKit verification passed: \(scenarios) shared-data/state scenarios, light and dark renders in \(output.path)")
    }

    @MainActor private static func tooltips(_ view: NSView) -> String {
        ([view.toolTip].compactMap { $0 } + view.subviews.map(tooltips)).joined(separator: "\n")
    }
    private static func withoutDisplayText(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.filter { $0.key != "display" }.mapValues(withoutDisplayText)
        }
        if let array = value as? [Any] { return array.map(withoutDisplayText) }
        return value
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw RuntimeError(message) }
    }
    @MainActor private static func render(_ root: NSView, name: String, output: URL) throws {
        let window = NSWindow(contentRect: root.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = root
        root.wantsLayer = true
        for (mode, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)!
            window.appearance = appearance
            var rendered: Data?
            appearance.performAsCurrentDrawingAppearance {
                root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                root.displayIfNeeded()
                if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                    root.cacheDisplay(in: root.bounds, to: bitmap)
                    rendered = bitmap.representation(using: .png, properties: [:])
                }
            }
            guard let rendered, rendered.count > 1000 else { throw RuntimeError("AppKit rendering failed: \(name)/\(mode)") }
            try rendered.write(to: output.appendingPathComponent("\(name)-\(mode).png"))
        }
        window.contentView = nil
    }
}
