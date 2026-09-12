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
        guard CommandLine.arguments.count == 3 else { throw RuntimeError("usage: VerifyMenu FIXTURES OUTPUT") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var scenarios = 0
        for name in ["complete", "unknown", "missing-breakdown", "missing-percent", "invalid-numbers", "partial", "unavailable", "failure", "cache-pending", "partial-cache-pending"] {
            let payload = try JSONDecoder().decode(RateLimitPayload.self, from: Data(contentsOf: fixtures.appendingPathComponent("\(name).json")))
            guard let local = payload.localUsage, let freshness = payload.refresh else { throw RuntimeError("Missing shared snapshot: \(name)") }
            // Independent fixture expectations supplement GUI/CLI/MCP parity.
            if name == "complete" {
                try require(local.totalTokens == 1000 && local.todayCost?.estimatedCostUSD == 0.004 && local.todayCredits?.estimatedCredits == 0.1, "Unexpected fixture amounts")
            }
            let rate = RateLimitsMenuView(frame: NSRect(x: 0, y: 0, width: 440, height: 220))
            let reset = ResetCreditsMenuView(frame: NSRect(x: 0, y: 0, width: 440, height: 90))
            let usage = LocalUsageMenuView(frame: NSRect(x: 0, y: 0, width: 440, height: 398))
            rate.update(weekly: payload.selectedRateLimit?.weeklyWindow, forecast: nil,
                        weeklyQuotaCost: local.weeklyQuotaCost, credits: payload.selectedRateLimit?.credits, freshness: freshness)
            reset.update(payload.resetCredits, freshness: freshness.resetCredits)
            usage.update(local, freshness: freshness.localUsage)
            let localText = tooltips(usage)
            for label in [local.display?.estimatedCreditsLabel, local.display?.scanStatusLabel] {
                if let label { try require(localText.contains(label), "GUI lost a shared local display label: \(name): \(label)") }
            }
            if name == "unknown" { try require(localText.contains("Raw-Private-Model"), "GUI lost the raw unknown model") }
            if name == "missing-breakdown" {
                try require(local.todayCost?.estimatedCostUSD == nil && local.todayCredits?.estimatedCredits == nil,
                            "Incomplete token breakdown became free usage")
                try require(localText.contains(AppText.unpricedUsageDetails(local.unpricedUsage) ?? "missing details"),
                            "GUI lost incomplete-breakdown details")
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
