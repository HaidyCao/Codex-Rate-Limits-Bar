import AppKit
import Network
import CodexRateLimitsCore
import Darwin
import Foundation
import UserNotifications

struct AutoLaunchManager {
    static let label = "local.codex.rate-limits-bar.autostart"
    static let preferenceKey = "autoLaunchEnabled"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    static var preferredEnabled: Bool {
        guard UserDefaults.standard.object(forKey: preferenceKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: preferenceKey)
    }

    @discardableResult
    static func applyStoredPreference() throws -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: preferenceKey) == nil {
            defaults.set(true, forKey: preferenceKey)
        }

        let enabled = defaults.bool(forKey: preferenceKey)
        if enabled {
            try enable()
        } else {
            try disable()
        }
        return enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try enable()
        } else {
            try disable()
        }
        UserDefaults.standard.set(enabled, forKey: preferenceKey)
    }

    private static func enable() throws {
        try writePlist()
    }

    private static func disable() throws {
        try runLaunchctl(["bootout", userDomain, plistURL.path], allowFailure: true)
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private static func writePlist() throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-g", appPath],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
    }

    private static var appPath: String {
        let installedApp = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications")
            .appendingPathComponent("Codex Rate Limits Bar.app")
        if FileManager.default.fileExists(atPath: installedApp.path) {
            return installedApp.path
        }
        return Bundle.main.bundlePath
    }

    private static var userDomain: String {
        "gui/\(getuid())"
    }

    private static func runLaunchctl(_ arguments: [String], allowFailure: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 && !allowFailure {
            let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let detail = [stderrText, stdoutText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw RuntimeError(detail.isEmpty ? "launchctl \(arguments.joined(separator: " ")) failed" : detail)
        }
    }
}

struct StatusItemPreferences {
    static let localUsageStatusItemVisibleKey = "localUsageStatusItemVisible"

    static var isLocalUsageStatusItemVisible: Bool {
        guard UserDefaults.standard.object(forKey: localUsageStatusItemVisibleKey) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: localUsageStatusItemVisibleKey)
    }

    static func setLocalUsageStatusItemVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: localUsageStatusItemVisibleKey)
    }
}

struct QuotaAlertPreferences {
    private static let enabledKey = "quotaAlertsEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }
}

private struct RateLimitUIUpdate: Sendable {
    let weekly: RateLimitWindow?
    let error: String?
    let credits: CreditsSnapshot?
    let accountContext: CodexAccountContext?
    let resetCredits: ResetCreditsSnapshot?
    let sampledAt: Date?
    let outcomes: [RefreshSource: RefreshOutcome]

    init(_ payload: RateLimitPayload) {
        weekly = payload.selectedRateLimit?.weeklyWindow
        error = payload.rateLimitError
        credits = payload.selectedRateLimit?.credits
        accountContext = payload.accountContext
        resetCredits = payload.resetCredits
        sampledAt = RefreshOutcome.date(payload.fetchedAtIso)
        outcomes = RefreshOutcome.official(payload)
    }
}

final class RateLimitsMenuView: NSView {
    private let cardView = RateLimitsCardView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        cardView.frame = NSRect(x: 16, y: 8, width: bounds.width - 32, height: bounds.height - 16)
        addSubview(cardView)
    }

    func update(
        weekly: RateLimitWindow?,
        forecast: QuotaForecast?,
        weeklyQuotaCost: WeeklyQuotaCostEstimate?,
        credits: CreditsSnapshot?,
        freshness: RefreshSnapshot
    ) {
        cardView.update(weekly: weekly, forecast: forecast, weeklyQuotaCost: weeklyQuotaCost, credits: credits, freshness: freshness)
    }
}

class RateLimitsDrawingView: NSView {
    private var weekly: RateLimitWindow?
    private var forecast: QuotaForecast?
    private var weeklyQuotaCost: WeeklyQuotaCostEstimate?
    private var credits: CreditsSnapshot?
    private var freshness: RefreshSnapshot?

    override var isFlipped: Bool {
        true
    }

    func update(
        weekly: RateLimitWindow?,
        forecast: QuotaForecast?,
        weeklyQuotaCost: WeeklyQuotaCostEstimate?,
        credits: CreditsSnapshot?,
        freshness: RefreshSnapshot
    ) {
        self.weekly = weekly
        self.forecast = forecast
        self.weeklyQuotaCost = weeklyQuotaCost
        self.credits = credits
        self.freshness = freshness
        toolTip = AppText.refreshDetails(freshness) + "\n" + AppText.officialCreditsBalance(credits) + "\n" + AppText.costEstimateDisclaimer
            + "\n" + AppText.weeklyValuationDetails(weeklyQuotaCost?.valuation)
            + (AppText.unpricedUsageDetails(weeklyQuotaCost?.unpricedUsage).map { "\n" + $0 } ?? "")
            + ((weeklyQuotaCost?.unpricedModels?.isEmpty == false) ? "\n" + (weeklyQuotaCost?.unpricedModels?.joined(separator: ", ") ?? "") : "")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let labelColor = NSColor.labelColor
        let secondaryColor = NSColor.secondaryLabelColor

        drawSymbol("chart.bar.fill", in: NSRect(x: 12, y: 12, width: 14, height: 14), color: secondaryColor)
        drawText(AppText.usageTitle, in: NSRect(x: 32, y: 10, width: 200, height: 18), font: .systemFont(ofSize: 12, weight: .bold), color: labelColor)

        drawQuotaRow(label: AppText.weeklyLimit, window: weekly, y: 36)
        drawForecast(forecast, y: 72)
        if freshness?.quota.isStale == true || freshness?.localUsage.isStale == true {
            drawText(AppText.staleWeeklyValue, in: NSRect(x: 32, y: 93, width: bounds.width - 44, height: 16), font: .systemFont(ofSize: 10.5), color: secondaryColor)
        } else {
            drawWeeklyQuotaCost(weeklyQuotaCost, y: 94)
        }
        drawText(AppText.weeklyValuationSummary(weeklyQuotaCost?.valuation), in: NSRect(x: 32, y: 115, width: bounds.width - 44, height: 16), font: .systemFont(ofSize: 10.5), color: secondaryColor)
        drawText(AppText.officialCreditsBalance(credits), in: NSRect(x: 32, y: 137, width: bounds.width - 44, height: 16), font: .systemFont(ofSize: 10.5, weight: .medium), color: freshness?.credits.isStale == true || freshness?.credits.error != nil ? secondaryColor : labelColor)
        drawText(AppText.freshnessSummary(freshness?.quota, source: .quota), in: NSRect(x: 12, y: 158, width: bounds.width - 24, height: 16), font: .systemFont(ofSize: 10), color: secondaryColor)
        drawText(AppText.freshnessSummary(freshness?.credits, source: .credits), in: NSRect(x: 12, y: 178, width: bounds.width - 24, height: 16), font: .systemFont(ofSize: 10), color: secondaryColor)
    }

    private func drawQuotaRow(label: String, window: RateLimitWindow?, y: CGFloat) {
        let remaining = window?.remainingPercent
        let colors = freshness?.quota.isStale == true || freshness?.quota.error != nil
            ? (start: NSColor.tertiaryLabelColor, end: NSColor.tertiaryLabelColor) : gradientColors(for: remaining)
        let value = remaining.map { "\($0)%" } ?? "--"
        let reset = formatResetDisplay(window)
        let rightLabel = reset.isEmpty ? value : "\(value) · \(reset)"

        drawText(label, in: NSRect(x: 12, y: y, width: 120, height: 16), font: .systemFont(ofSize: 11, weight: .semibold), color: NSColor.secondaryLabelColor)
        drawText(rightLabel, in: NSRect(x: 132, y: y, width: bounds.width - 144, height: 16), font: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold), color: NSColor.labelColor, alignment: .right)

        let barRect = NSRect(x: 12, y: y + 21, width: bounds.width - 24, height: 5)
        drawRoundedRect(barRect, fill: NSColor.separatorColor.withAlphaComponent(0.2), stroke: .clear, radius: 2.5)

        if let remaining {
            let fillWidth = max(0, min(1, CGFloat(remaining) / 100)) * barRect.width
            if fillWidth > 0 {
                let fillRect = NSRect(x: barRect.minX, y: barRect.minY, width: fillWidth, height: barRect.height)
                let path = NSBezierPath(roundedRect: fillRect, xRadius: 2.5, yRadius: 2.5)
                if let gradient = NSGradient(starting: colors.start, ending: colors.end) {
                    gradient.draw(in: path, angle: 0.0)
                } else {
                    colors.start.setFill()
                    path.fill()
                }
            }
        }

        if let budget = forecast?.budgetRemainingPercent {
            let ratio = max(0, min(1, CGFloat(budget) / 100))
            let markerX = barRect.minX + ratio * barRect.width
            let markerColor = NSColor.labelColor.withAlphaComponent(0.78)
            let marker = NSBezierPath()
            marker.move(to: NSPoint(x: markerX, y: barRect.minY - 2))
            marker.line(to: NSPoint(x: markerX, y: barRect.maxY + 2))
            marker.lineWidth = 1.5
            markerColor.setStroke()
            marker.stroke()
        }
    }

    private func drawForecast(_ forecast: QuotaForecast?, y: CGFloat) {
        guard let forecast else {
            drawSymbol("waveform.path.ecg", in: NSRect(x: 12, y: y, width: 14, height: 14), color: .tertiaryLabelColor)
            drawText(AppText.quotaForecastLabelPlaceholder, in: NSRect(x: 32, y: y - 1, width: bounds.width - 44, height: 16), font: .systemFont(ofSize: 10.5, weight: .medium), color: .secondaryLabelColor)
            return
        }

        let color: NSColor
        let symbol: String
        switch forecast.status {
        case .exhausted:
            color = .systemRed
            symbol = "exclamationmark.circle.fill"
        case .atRisk:
            color = .systemOrange
            symbol = "exclamationmark.triangle.fill"
        case .onPace:
            color = .systemGreen
            symbol = "checkmark.circle.fill"
        case .insufficientData:
            color = .secondaryLabelColor
            symbol = "waveform.path.ecg"
        }
        drawSymbol(symbol, in: NSRect(x: 12, y: y, width: 14, height: 14), color: color)
        drawText(AppText.quotaForecastLabel(forecast), in: NSRect(x: 32, y: y - 1, width: bounds.width - 44, height: 16), font: .systemFont(ofSize: 10.5, weight: .medium), color: color)
    }

    private func drawWeeklyQuotaCost(_ estimate: WeeklyQuotaCostEstimate?, y: CGFloat) {
        let color: NSColor = estimate?.estimatedQuotaUSD == nil ? .secondaryLabelColor : .labelColor
        drawSymbol("dollarsign.circle.fill", in: NSRect(x: 12, y: y, width: 14, height: 14), color: .systemTeal)
        drawText(
            AppText.weeklyQuotaEstimatedCost(estimate),
            in: NSRect(x: 32, y: y - 1, width: bounds.width - 44, height: 16),
            font: .systemFont(ofSize: 10.5, weight: .medium),
            color: color
        )
    }

    private func gradientColors(for remaining: Int?) -> (start: NSColor, end: NSColor) {
        guard let remaining else {
            return (NSColor.tertiaryLabelColor, NSColor.tertiaryLabelColor)
        }
        if remaining <= 10 {
            return (NSColor(red: 0.92, green: 0.30, blue: 0.26, alpha: 1.0), NSColor(red: 0.82, green: 0.20, blue: 0.16, alpha: 1.0))
        }
        if remaining <= 25 {
            return (NSColor(red: 0.95, green: 0.77, blue: 0.06, alpha: 1.0), NSColor(red: 0.90, green: 0.65, blue: 0.04, alpha: 1.0))
        }
        return (NSColor(red: 0.15, green: 0.80, blue: 0.44, alpha: 1.0), NSColor(red: 0.18, green: 0.70, blue: 0.35, alpha: 1.0))
    }

    private func formatResetDisplay(_ window: RateLimitWindow?) -> String {
        guard let date = window?.resetDate else { return "" }
        return AppText.resetDisplay(date, includeDate: true)
    }

    private func drawRoundedRect(_ rect: NSRect, fill: NSColor, stroke: NSColor, radius: CGFloat) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        if stroke != .clear {
            stroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        NSString(string: text).draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .bold)
            let configured = image.withSymbolConfiguration(config) ?? image
            let tinted = configured.tinted(with: color)
            let imgSize = tinted.size
            guard imgSize.width > 0, imgSize.height > 0 else { return }
            let aspect = imgSize.width / imgSize.height
            var targetWidth = rect.width
            var targetHeight = rect.height
            if aspect > 1.0 {
                targetHeight = rect.width / aspect
            } else {
                targetWidth = rect.height * aspect
            }
            let targetX = rect.minX + (rect.width - targetWidth) / 2
            let targetY = rect.minY + (rect.height - targetHeight) / 2
            tinted.draw(in: NSRect(x: targetX, y: targetY, width: targetWidth, height: targetHeight))
        }
    }
}

class RateLimitsCardView: NSVisualEffectView {
    private let drawingView = RateLimitsDrawingView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        material = .popover
        blendingMode = .withinWindow
        state = .active
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        updateBorderColor()

        drawingView.frame = bounds
        drawingView.autoresizingMask = [.width, .height]
        addSubview(drawingView)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.borderColor = isDark
            ? NSColor(white: 1.0, alpha: 0.15).cgColor
            : NSColor(white: 0.0, alpha: 0.08).cgColor
    }

    func update(
        weekly: RateLimitWindow?,
        forecast: QuotaForecast?,
        weeklyQuotaCost: WeeklyQuotaCostEstimate?,
        credits: CreditsSnapshot?,
        freshness: RefreshSnapshot
    ) {
        drawingView.update(weekly: weekly, forecast: forecast, weeklyQuotaCost: weeklyQuotaCost, credits: credits, freshness: freshness)
    }
}

final class ResetCreditsMenuView: NSView {
    private let cardView = ResetCreditsCardView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        cardView.frame = NSRect(x: 16, y: 4, width: bounds.width - 32, height: bounds.height - 8)
        addSubview(cardView)
    }

    func update(_ snapshot: ResetCreditsSnapshot?, freshness: DataFreshness) {
        let h = Self.height(for: snapshot)
        setFrameSize(NSSize(width: frame.width, height: h))
        cardView.frame = NSRect(x: 16, y: 4, width: bounds.width - 32, height: h - 8)
        cardView.update(snapshot, freshness: freshness)
    }

    static func height(for snapshot: ResetCreditsSnapshot?) -> CGFloat {
        let rows = min(snapshot?.display?.detailLabels?.count ?? 0, 4)
        if rows == 0 {
            return 88
        }
        return CGFloat(72 + rows * 18)
    }
}

class ResetCreditsDrawingView: NSView {
    private var freshness: DataFreshness?
    private var snapshot: ResetCreditsSnapshot?

    override var isFlipped: Bool {
        true
    }

    func update(_ snapshot: ResetCreditsSnapshot?, freshness: DataFreshness) {
        self.snapshot = snapshot
        self.freshness = freshness
        toolTip = AppText.freshnessDetails(freshness, source: .resetCredits)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let labelColor = NSColor.labelColor
        let secondaryColor = NSColor.secondaryLabelColor
        let availableCount = snapshot?.availableCount ?? 0
        let accent = availableCount > 0 ? NSColor.systemOrange : secondaryColor

        drawSymbol("ticket.fill", in: NSRect(x: 12, y: 12, width: 14, height: 14), color: secondaryColor)
        drawText(AppText.resetCreditsTitle, in: NSRect(x: 32, y: 10, width: 88, height: 17), font: .systemFont(ofSize: 12, weight: .bold), color: labelColor)

        let summary = snapshot?.display?.summaryLabel ?? AppText.availableCount(nil)
        drawText(summary, in: NSRect(x: 120, y: 10, width: bounds.width - 132, height: 17), font: .systemFont(ofSize: 12, weight: .bold), color: freshness?.isStale == true || freshness?.error != nil ? secondaryColor : accent, alignment: .right)

        drawText(AppText.freshnessSummary(freshness, source: .resetCredits), in: NSRect(x: 12, y: bounds.height - 20, width: bounds.width - 24, height: 16), font: .systemFont(ofSize: 10), color: secondaryColor)
        let rows = Array((snapshot?.display?.detailLabels ?? []).prefix(4))
        if rows.isEmpty {
            let placeholder = snapshot?.availableCount == 0 ? AppText.noResetCredits : AppText.resetCreditsUnavailable
            drawText(placeholder, in: NSRect(x: 12, y: 34, width: bounds.width - 24, height: 16), font: .systemFont(ofSize: 10.5, weight: .regular), color: secondaryColor)
            return
        }

        for (index, row) in rows.enumerated() {
            drawText(row, in: NSRect(x: 12, y: 34 + CGFloat(index * 18), width: bounds.width - 24, height: 16), font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium), color: labelColor)
        }
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        NSString(string: text).draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .bold)
            let configured = image.withSymbolConfiguration(config) ?? image
            let tinted = configured.tinted(with: color)
            let imgSize = tinted.size
            guard imgSize.width > 0, imgSize.height > 0 else { return }
            let aspect = imgSize.width / imgSize.height
            var targetWidth = rect.width
            var targetHeight = rect.height
            if aspect > 1.0 {
                targetHeight = rect.width / aspect
            } else {
                targetWidth = rect.height * aspect
            }
            let targetX = rect.minX + (rect.width - targetWidth) / 2
            let targetY = rect.minY + (rect.height - targetHeight) / 2
            tinted.draw(in: NSRect(x: targetX, y: targetY, width: targetWidth, height: targetHeight))
        }
    }
}

class ResetCreditsCardView: NSVisualEffectView {
    private let drawingView = ResetCreditsDrawingView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        material = .popover
        blendingMode = .withinWindow
        state = .active
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        updateBorderColor()

        drawingView.frame = bounds
        drawingView.autoresizingMask = [.width, .height]
        addSubview(drawingView)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.borderColor = isDark
            ? NSColor(white: 1.0, alpha: 0.15).cgColor
            : NSColor(white: 0.0, alpha: 0.08).cgColor
    }

    func update(_ snapshot: ResetCreditsSnapshot?, freshness: DataFreshness) {
        drawingView.update(snapshot, freshness: freshness)
    }
}

final class PreferencesMenuView: NSView {
    private let cardView = PreferencesCardView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        cardView.frame = NSRect(x: 16, y: 2, width: bounds.width - 32, height: bounds.height - 4)
        addSubview(cardView)
    }

    var isAutoLaunchChecked: Bool {
        cardView.isAutoLaunchChecked
    }

    var isLocalUsageStatusItemChecked: Bool {
        cardView.isLocalUsageStatusItemChecked
    }

    var isQuotaAlertsChecked: Bool {
        cardView.isQuotaAlertsChecked
    }

    func configure(
        autoLaunchTarget: AnyObject?,
        autoLaunchAction: Selector,
        localUsageStatusItemTarget: AnyObject?,
        localUsageStatusItemAction: Selector,
        quotaAlertsTarget: AnyObject?,
        quotaAlertsAction: Selector
    ) {
        cardView.configure(
            autoLaunchTarget: autoLaunchTarget,
            autoLaunchAction: autoLaunchAction,
            localUsageStatusItemTarget: localUsageStatusItemTarget,
            localUsageStatusItemAction: localUsageStatusItemAction,
            quotaAlertsTarget: quotaAlertsTarget,
            quotaAlertsAction: quotaAlertsAction
        )
    }

    func updateAutoLaunch(enabled: Bool) {
        cardView.updateAutoLaunch(enabled: enabled)
    }

    func updateLocalUsageStatusItem(visible: Bool) {
        cardView.updateLocalUsageStatusItem(visible: visible)
    }

    func updateQuotaAlerts(enabled: Bool) {
        cardView.updateQuotaAlerts(enabled: enabled)
    }
}

class PreferencesCardView: NSVisualEffectView {
    private let autoLaunchCheckbox = NSButton(checkboxWithTitle: AppText.launchAtLogin, target: nil, action: nil)
    private let localUsageStatusItemCheckbox = NSButton(checkboxWithTitle: AppText.showLocalUsageStatusItem, target: nil, action: nil)
    private let quotaAlertsCheckbox = NSButton(checkboxWithTitle: AppText.enableQuotaAlerts, target: nil, action: nil)
    private let firstSeparator = NSBox()
    private let secondSeparator = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        material = .popover
        blendingMode = .withinWindow
        state = .active
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        updateBorderColor()

        for checkbox in [autoLaunchCheckbox, localUsageStatusItemCheckbox, quotaAlertsCheckbox] {
            checkbox.font = .systemFont(ofSize: 12, weight: .semibold)
            checkbox.setButtonType(.switch)
            addSubview(checkbox)
        }

        for separator in [firstSeparator, secondSeparator] {
            separator.boxType = .separator
            addSubview(separator)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.borderColor = isDark
            ? NSColor(white: 1.0, alpha: 0.15).cgColor
            : NSColor(white: 0.0, alpha: 0.1).cgColor
    }

    var isAutoLaunchChecked: Bool {
        autoLaunchCheckbox.state == .on
    }

    var isLocalUsageStatusItemChecked: Bool {
        localUsageStatusItemCheckbox.state == .on
    }

    var isQuotaAlertsChecked: Bool {
        quotaAlertsCheckbox.state == .on
    }

    func configure(
        autoLaunchTarget: AnyObject?,
        autoLaunchAction: Selector,
        localUsageStatusItemTarget: AnyObject?,
        localUsageStatusItemAction: Selector,
        quotaAlertsTarget: AnyObject?,
        quotaAlertsAction: Selector
    ) {
        autoLaunchCheckbox.target = autoLaunchTarget
        autoLaunchCheckbox.action = autoLaunchAction
        localUsageStatusItemCheckbox.target = localUsageStatusItemTarget
        localUsageStatusItemCheckbox.action = localUsageStatusItemAction
        quotaAlertsCheckbox.target = quotaAlertsTarget
        quotaAlertsCheckbox.action = quotaAlertsAction
    }

    func updateAutoLaunch(enabled: Bool) {
        autoLaunchCheckbox.state = enabled ? .on : .off
    }

    func updateLocalUsageStatusItem(visible: Bool) {
        localUsageStatusItemCheckbox.state = visible ? .on : .off
    }

    func updateQuotaAlerts(enabled: Bool) {
        quotaAlertsCheckbox.state = enabled ? .on : .off
    }

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()
        let rowHeight = floor(bounds.height / 3)
        let checkboxY = floor((rowHeight - 20) / 2) - 3
        autoLaunchCheckbox.frame = NSRect(x: 12, y: checkboxY, width: bounds.width - 24, height: 26)
        localUsageStatusItemCheckbox.frame = NSRect(x: 12, y: rowHeight + checkboxY, width: bounds.width - 24, height: 26)
        quotaAlertsCheckbox.frame = NSRect(x: 12, y: rowHeight * 2 + checkboxY, width: bounds.width - 24, height: 26)
        firstSeparator.frame = NSRect(x: 12, y: rowHeight, width: bounds.width - 24, height: 1)
        secondSeparator.frame = NSRect(x: 12, y: rowHeight * 2, width: bounds.width - 24, height: 1)
    }
}

final class LocalUsageMenuView: NSView {
    private let cardView = LocalUsageCardView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        cardView.frame = NSRect(x: 16, y: 6, width: bounds.width - 32, height: bounds.height - 12)
        addSubview(cardView)
    }

    func update(_ snapshot: LocalUsageSnapshot?, freshness: DataFreshness) {
        cardView.update(snapshot, freshness: freshness)
    }
}

class LocalUsageDrawingView: NSView {
    private var freshness: DataFreshness?
    private var snapshot: LocalUsageSnapshot?

    override var isFlipped: Bool {
        true
    }

    func update(_ snapshot: LocalUsageSnapshot?, freshness: DataFreshness) {
        self.snapshot = snapshot
        self.freshness = freshness
        toolTip = [AppText.todayEstimatedCredits(snapshot?.todayCredits),
                   AppText.pricingCoverage(cost: snapshot?.todayCost, credits: snapshot?.todayCredits),
                   AppText.unpricedUsageDetails(snapshot?.unpricedUsage), AppText.pricingDetails(snapshot?.pricing),
                   snapshot.map(AppText.scanDetails), AppText.creditsEstimateDetails, AppText.freshnessDetails(freshness, source: .localUsage)]
            .compactMap { $0 }.joined(separator: "\n")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let labelColor = freshness?.isStale == true || freshness?.error != nil ? NSColor.secondaryLabelColor : NSColor.labelColor
        let secondaryColor = NSColor.secondaryLabelColor

        let blue = NSColor.systemBlue
        let purple = NSColor.systemPurple
        let green = NSColor.systemGreen

        let subCardFill = isDark ? NSColor.white.withAlphaComponent(0.055) : NSColor.black.withAlphaComponent(0.035)
        let subCardStroke = isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.05)

        let totalTokens = snapshot?.totalTokens ?? 0
        let inputTokens = snapshot?.inputTokens ?? 0
        let cachedInputTokens = snapshot?.cachedInputTokens ?? 0
        let cacheWriteInputTokens = snapshot?.cacheWriteInputTokens ?? 0
        let newInputTokens = max(0, inputTokens - cachedInputTokens - cacheWriteInputTokens)
        let outputTokens = snapshot?.outputTokens ?? 0
        let eventCount = snapshot?.eventCount ?? 0
        let cacheHitPercent = snapshot?.cacheHitPercent

        drawSymbol("cpu.fill", in: NSRect(x: 12, y: 12, width: 14, height: 14), color: secondaryColor)
        drawText(AppText.localUsageTitle, in: NSRect(x: 32, y: 10, width: 250, height: 18), font: .systemFont(ofSize: 12, weight: .bold), color: labelColor)

        let unavailable = snapshot == nil || snapshot?.diagnostics?.status == .unavailable
        let rawTotal = unavailable ? "--" : formatRawNumber(totalTokens)
        let rawFont = NSFont.monospacedDigitSystemFont(ofSize: 32, weight: .bold)
        let rawWidth = ceil(NSString(string: rawTotal).size(withAttributes: [.font: rawFont]).width)
        drawText(rawTotal, in: NSRect(x: 12, y: 32, width: min(rawWidth + 4, bounds.width - 176), height: 42), font: rawFont, color: labelColor)

        let requestRect = NSRect(x: bounds.width - 152, y: 12, width: 140, height: 58)
        drawSubCard(requestRect, fill: subCardFill, stroke: subCardStroke)
        drawText(AppText.todayEstimatedCostCardTitle(requests: eventCount), in: NSRect(x: requestRect.minX + 10, y: requestRect.minY + 6, width: requestRect.width - 20, height: 16), font: .systemFont(ofSize: 10.5, weight: .semibold), color: secondaryColor)
        let cost = USDFormatter.string(unavailable ? nil : snapshot?.todayCost?.estimatedCostUSD)
        let costSuffix = snapshot?.diagnostics?.status == .partial ? "*" : snapshot?.todayCost?.isPartial == true ? "+" : ""
        drawText("\(cost)\(costSuffix)", in: NSRect(x: requestRect.minX + 10, y: requestRect.minY + 24, width: requestRect.width - 20, height: 24), font: .monospacedDigitSystemFont(ofSize: 18, weight: .bold), color: labelColor)

        let padding: CGFloat = 12
        let gap: CGFloat = 8
        let gridWidth = bounds.width - padding * 2
        let cardWidth = floor((gridWidth - gap) / 2)
        let cardHeight: CGFloat = 52

        let rowOneY: CGFloat = 84
        let rowTwoY: CGFloat = 144

        let rect1 = NSRect(x: padding, y: rowOneY, width: cardWidth, height: cardHeight)
        drawMetricCard(rect1, title: AppText.newInput, value: unavailable ? "--" : TokenAmountFormatter.compact(newInputTokens, maximumFractionDigits: 1), tint: blue, fill: subCardFill, stroke: subCardStroke)

        let rect2 = NSRect(x: padding + cardWidth + gap, y: rowOneY, width: cardWidth, height: cardHeight)
        drawMetricCard(rect2, title: AppText.output, value: unavailable ? "--" : TokenAmountFormatter.compact(outputTokens, maximumFractionDigits: 1), tint: purple, fill: subCardFill, stroke: subCardStroke)

        let rect3 = NSRect(x: padding, y: rowTwoY, width: cardWidth, height: cardHeight)
        drawMetricCard(rect3, title: AppText.hit, value: unavailable ? "--" : TokenAmountFormatter.compact(cachedInputTokens, maximumFractionDigits: 2), tint: green, fill: subCardFill, stroke: subCardStroke)

        let rect4 = NSRect(x: padding + cardWidth + gap, y: rowTwoY, width: cardWidth, height: cardHeight)
        drawCacheHitCard(rect4, percent: cacheHitPercent, fill: subCardFill, stroke: subCardStroke, tint: green)

        drawText(AppText.todayEstimatedCredits(unavailable ? nil : snapshot?.todayCredits), in: NSRect(x: 12, y: 210, width: bounds.width - 24, height: 20), font: .monospacedDigitSystemFont(ofSize: 13, weight: .semibold), color: labelColor)
        drawText(AppText.pricingCoverage(cost: snapshot?.todayCost, credits: snapshot?.todayCredits), in: NSRect(x: 12, y: 234, width: bounds.width - 24, height: 16), font: .systemFont(ofSize: 10.5), color: secondaryColor)
        drawText(AppText.scanStatus(snapshot?.diagnostics), in: NSRect(x: 12, y: 254, width: bounds.width - 24, height: 16), font: .systemFont(ofSize: 10.5, weight: .medium), color: snapshot?.diagnostics?.status.isIncomplete == true ? .systemOrange : secondaryColor)
        drawText(AppText.billingAssumptions(snapshot?.billingAssumptions) ?? "", in: NSRect(x: 12, y: 276, width: bounds.width - 24, height: 16), font: .systemFont(ofSize: 10.5), color: secondaryColor)
        drawText(AppText.unpricedModels(cost: snapshot?.todayCost, credits: snapshot?.todayCredits) ?? "", in: NSRect(x: 12, y: 298, width: bounds.width - 24, height: 16), font: .systemFont(ofSize: 10.5), color: secondaryColor)
        drawText(AppText.pricingVersion(snapshot?.pricing), in: NSRect(x: 12, y: 320, width: bounds.width - 24, height: 16), font: .systemFont(ofSize: 10.5), color: snapshot?.pricing?.configurationError == nil ? secondaryColor : .systemOrange)
        drawText(AppText.creditsEstimateNote, in: NSRect(x: 12, y: 342, width: bounds.width - 24, height: 16), font: .systemFont(ofSize: 10), color: secondaryColor)
        drawText(AppText.freshnessSummary(freshness, source: .localUsage), in: NSRect(x: 12, y: 364, width: bounds.width - 24, height: 16), font: .systemFont(ofSize: 10), color: secondaryColor)
    }

    private func drawSubCard(_ rect: NSRect, fill: NSColor, stroke: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private func drawMetricCard(_ rect: NSRect, title: String, value: String, tint: NSColor, fill: NSColor, stroke: NSColor) {
        drawSubCard(rect, fill: fill, stroke: stroke)
        drawText(title, in: NSRect(x: rect.minX + 12, y: rect.minY + 7, width: rect.width - 24, height: 16), font: .systemFont(ofSize: 11, weight: .semibold), color: NSColor.secondaryLabelColor)
        drawText(value, in: NSRect(x: rect.minX + 12, y: rect.minY + 26, width: rect.width - 24, height: 20), font: .monospacedDigitSystemFont(ofSize: 16, weight: .bold), color: NSColor.labelColor)
        drawVerticalAccentBar(in: rect, color: tint)
    }

    private func drawCacheHitCard(_ rect: NSRect, percent: Double?, fill: NSColor, stroke: NSColor, tint: NSColor) {
        drawSubCard(rect, fill: fill, stroke: stroke)
        drawText(AppText.cacheHitRate, in: NSRect(x: rect.minX + 12, y: rect.minY + 7, width: rect.width - 86, height: 16), font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor)
        drawText(formatPercent(percent), in: NSRect(x: rect.maxX - 70, y: rect.minY + 7, width: 58, height: 16), font: .monospacedDigitSystemFont(ofSize: 12, weight: .bold), color: tint, alignment: .right)

        let barRect = NSRect(x: rect.minX + 12, y: rect.minY + 31, width: rect.width - 24, height: 5)
        let pathBg = NSBezierPath(roundedRect: barRect, xRadius: 2.5, yRadius: 2.5)
        NSColor.separatorColor.withAlphaComponent(0.2).setFill()
        pathBg.fill()

        if let percent {
            let width = max(0, min(1, percent / 100)) * barRect.width
            if width > 0 {
                let fillRect = NSRect(x: barRect.minX, y: barRect.minY, width: width, height: barRect.height)
                let pathFill = NSBezierPath(roundedRect: fillRect, xRadius: 2.5, yRadius: 2.5)
                let startCol = NSColor(red: 0.0, green: 0.8, blue: 0.6, alpha: 1.0)
                let endCol = NSColor(red: 0.0, green: 0.6, blue: 0.5, alpha: 1.0)
                if let gradient = NSGradient(starting: startCol, ending: endCol) {
                    gradient.draw(in: pathFill, angle: 0.0)
                } else {
                    tint.withAlphaComponent(0.9).setFill()
                    pathFill.fill()
                }
            }
        }
    }

    private func drawVerticalAccentBar(in rect: NSRect, color: NSColor) {
        color.withAlphaComponent(0.85).setFill()
        let bar = NSBezierPath(roundedRect: NSRect(x: rect.minX + 1.5, y: rect.minY + 12, width: 3, height: 28), xRadius: 1.5, yRadius: 1.5)
        bar.fill()
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        NSString(string: text).draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .bold)
            let configured = image.withSymbolConfiguration(config) ?? image
            let tinted = configured.tinted(with: color)
            let imgSize = tinted.size
            guard imgSize.width > 0, imgSize.height > 0 else { return }
            let aspect = imgSize.width / imgSize.height
            var targetWidth = rect.width
            var targetHeight = rect.height
            if aspect > 1.0 {
                targetHeight = rect.width / aspect
            } else {
                targetWidth = rect.height * aspect
            }
            let targetX = rect.minX + (rect.width - targetWidth) / 2
            let targetY = rect.minY + (rect.height - targetHeight) / 2
            tinted.draw(in: NSRect(x: targetX, y: targetY, width: targetWidth, height: targetHeight))
        }
    }

    private func formatRawNumber(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formatPercent(_ percent: Double?) -> String {
        guard let percent else { return "--" }
        return String(format: "%.1f%%", percent)
    }
}

class LocalUsageCardView: NSVisualEffectView {
    private let drawingView = LocalUsageDrawingView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        material = .popover
        blendingMode = .withinWindow
        state = .active
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        updateBorderColor()

        drawingView.frame = bounds
        drawingView.autoresizingMask = [.width, .height]
        addSubview(drawingView)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.borderColor = isDark
            ? NSColor(white: 1.0, alpha: 0.15).cgColor
            : NSColor(white: 0.0, alpha: 0.08).cgColor
    }

    func update(_ snapshot: LocalUsageSnapshot?, freshness: DataFreshness) {
        drawingView.update(snapshot, freshness: freshness)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let tokenStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let notificationCenter = UNUserNotificationCenter.current()
    private let quotaMonitor = QuotaMonitor()
    private let rateLimitsQueue = DispatchQueue(
        label: "local.codex.rate-limits-bar.rate-limits",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )
    private let localUsageQueue = DispatchQueue(
        label: "local.codex.rate-limits-bar.local-usage",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )
    private let menu = NSMenu()
    private let accountItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let rateLimitsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let rateLimitsView = RateLimitsMenuView(frame: NSRect(x: 0, y: 0, width: 440, height: 220))
    private let resetCreditsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let resetCreditsView = ResetCreditsMenuView(frame: NSRect(x: 0, y: 0, width: 440, height: 86))
    private let localUsageHeaderItem = NSMenuItem(title: "Local Today", action: nil, keyEquivalent: "")
    private let localConsumptionItem = NSMenuItem(title: "消耗 --", action: nil, keyEquivalent: "")
    private let localCacheHitItem = NSMenuItem(title: "命中 --", action: nil, keyEquivalent: "")
    private let localUsageDetailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let localUsagePanelItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let localUsagePanelView = LocalUsageMenuView(frame: NSRect(x: 0, y: 0, width: 440, height: 398))
    private let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let preferencesItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let preferencesView = PreferencesMenuView(frame: NSRect(x: 0, y: 0, width: 440, height: 104))
    private var refreshCoordinator = RefreshCoordinator(accountIdentity: CodexBackend.currentRefreshIdentity())
    private var refreshOperations: [Int: RefreshCancellation] = [:]
    private var heartbeatTimer: Timer?
    private let networkMonitor = NWPathMonitor()
    private var suspended = false
    private var currentResetCredits: ResetCreditsSnapshot?
    private var currentAutoLaunchError: String?
    private var currentWeeklyWindow: RateLimitWindow?
    private var currentQuotaSampleAt: Date?
    private var currentAccountContext: CodexAccountContext?
    private var currentCredits: CreditsSnapshot?
    private var currentLocalUsage: LocalUsageSnapshot?
    private var currentWeeklyRemaining: Int?
    private var currentQuotaForecast: QuotaForecast?
    private var currentResetAvailableCount: Int?
    private var currentQuotaMonitorError: String?
    private var currentNotificationError: String?
    private var quotaAlertsAuthorized = false
    private var lastLoggedErrorDetails: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("Keep the Codex rate limits status item available")
        setupStatusItem()
        setupTokenStatusItem()
        setupMenu()
        configureAutoLaunch()
        configureLocalUsageStatusItemVisibility()
        configureQuotaAlerts()
        refreshRateLimits()
        refreshLocalUsage()
        let timer = Timer(timeInterval: 5, target: self, selector: #selector(refreshHeartbeat), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let restored = self.refreshCoordinator.setNetworkAvailable(available)
                if restored { self.refreshRateLimits(reason: .recovery) }
                self.renderRefreshState()
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "local.codex.network"))
    }

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        updateStatusImage("W --")
        button.toolTip = AppText.rateLimitStatusTooltip
        statusItem.menu = menu
    }

    private func setupTokenStatusItem() {
        guard let button = tokenStatusItem.button else { return }
        button.imagePosition = .imageOnly
        button.contentTintColor = nil
        button.image = makeStatusImage(top: AppText.consumption(nil), bottom: AppText.cacheHit(nil))
        button.toolTip = AppText.localUsageStatusTooltip
        tokenStatusItem.menu = menu
    }

    private func setupMenu() {
        menu.delegate = self
        rateLimitsItem.isEnabled = false
        resetCreditsItem.isEnabled = false
        localUsageHeaderItem.isEnabled = false
        localConsumptionItem.isEnabled = false
        localCacheHitItem.isEnabled = false
        localUsageDetailItem.isEnabled = false
        localUsagePanelItem.isEnabled = false
        errorItem.isEnabled = false
        localUsageHeaderItem.isHidden = true
        localConsumptionItem.isHidden = true
        localCacheHitItem.isHidden = true
        localUsageDetailItem.isHidden = true
        rateLimitsItem.view = rateLimitsView
        resetCreditsItem.view = resetCreditsView
        localUsagePanelItem.view = localUsagePanelView
        errorItem.isHidden = true
        preferencesItem.view = preferencesView
        preferencesView.configure(
            autoLaunchTarget: self,
            autoLaunchAction: #selector(toggleAutoLaunch),
            localUsageStatusItemTarget: self,
            localUsageStatusItemAction: #selector(toggleLocalUsageStatusItemVisibility),
            quotaAlertsTarget: self,
            quotaAlertsAction: #selector(toggleQuotaAlerts)
        )
        updateAutoLaunchMenu(enabled: AutoLaunchManager.preferredEnabled)
        preferencesView.updateLocalUsageStatusItem(visible: StatusItemPreferences.isLocalUsageStatusItemVisible)
        preferencesView.updateQuotaAlerts(enabled: QuotaAlertPreferences.isEnabled)

        accountItem.isEnabled = false
        accountItem.title = AppText.accountSource(nil)
        menu.addItem(accountItem)
        menu.addItem(rateLimitsItem)
        menu.addItem(resetCreditsItem)
        menu.addItem(.separator())
        menu.addItem(localUsagePanelItem)
        menu.addItem(localUsageHeaderItem)
        menu.addItem(localConsumptionItem)
        menu.addItem(localCacheHitItem)
        menu.addItem(localUsageDetailItem)
        menu.addItem(.separator())
        menu.addItem(errorItem)
        menu.addItem(preferencesItem)
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: AppText.refreshNow, action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let rebuildItem = NSMenuItem(title: AppText.rebuildLocalUsage, action: #selector(rebuildLocalUsage), keyEquivalent: "")
        rebuildItem.target = self
        rebuildItem.toolTip = AppText.rebuildLocalUsageDetail
        menu.addItem(rebuildItem)

        let quitItem = NSMenuItem(title: AppText.quit, action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func refreshFromMenu() {
        refreshRateLimits()
        refreshLocalUsage()
    }

    @objc private func rebuildLocalUsage() {
        refreshLocalUsage(reason: .rebuild)
    }

    @objc private func refreshHeartbeat() {
        synchronizeAccount()
        for ticket in refreshCoordinator.expire(now: Date()) { refreshOperations[ticket.id]?.cancel() }
        refreshRateLimits(reason: .timer)
        refreshLocalUsage(reason: .timer)
        renderRefreshState()
    }

    func menuWillOpen(_ menu: NSMenu) { refreshHeartbeat() }

    @objc private func willSleep() {
        suspended = true
        for lane in RefreshLane.allCases {
            if let ticket = refreshCoordinator.invalidate(lane, now: Date()) { refreshOperations[ticket.id]?.cancel() }
        }
        renderRefreshState()
    }

    @objc private func didWake() {
        suspended = false
        refreshRateLimits(reason: .recovery)
        refreshLocalUsage(reason: .recovery)
    }

    func applicationWillTerminate(_ notification: Notification) {
        heartbeatTimer?.invalidate()
        networkMonitor.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for operation in refreshOperations.values { operation.cancel() }
    }

    @objc private func toggleAutoLaunch() {
        setAutoLaunch(enabled: preferencesView.isAutoLaunchChecked)
    }

    @objc private func toggleLocalUsageStatusItemVisibility() {
        setLocalUsageStatusItemVisible(preferencesView.isLocalUsageStatusItemChecked)
    }

    @objc private func toggleQuotaAlerts() {
        if preferencesView.isQuotaAlertsChecked {
            checkQuotaAlertAuthorization(requestIfNeeded: true)
        } else {
            setQuotaAlertsEnabled(false)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func configureAutoLaunch() {
        do {
            let enabled = try AutoLaunchManager.applyStoredPreference()
            updateAutoLaunchMenu(enabled: enabled)
        } catch {
            updateAutoLaunchMenu(enabled: AutoLaunchManager.preferredEnabled)
            showAutoLaunchError(error)
        }
    }

    private func setAutoLaunch(enabled: Bool) {
        do {
            try AutoLaunchManager.setEnabled(enabled)
            updateAutoLaunchMenu(enabled: enabled)
            currentAutoLaunchError = nil
            updateCombinedError()
        } catch {
            updateAutoLaunchMenu(enabled: AutoLaunchManager.preferredEnabled)
            showAutoLaunchError(error)
        }
    }

    private func updateAutoLaunchMenu(enabled: Bool) {
        preferencesView.updateAutoLaunch(enabled: enabled)
    }

    private func configureLocalUsageStatusItemVisibility() {
        updateLocalUsageStatusItemVisibility(visible: StatusItemPreferences.isLocalUsageStatusItemVisible)
    }

    private func setLocalUsageStatusItemVisible(_ visible: Bool) {
        StatusItemPreferences.setLocalUsageStatusItemVisible(visible)
        updateLocalUsageStatusItemVisibility(visible: visible)
    }

    private func updateLocalUsageStatusItemVisibility(visible: Bool) {
        preferencesView.updateLocalUsageStatusItem(visible: visible)
        tokenStatusItem.isVisible = visible
    }

    private func configureQuotaAlerts() {
        notificationCenter.delegate = self
        let enabled = QuotaAlertPreferences.isEnabled
        preferencesView.updateQuotaAlerts(enabled: enabled)
        guard enabled else { return }
        checkQuotaAlertAuthorization(requestIfNeeded: true)
    }

    private func checkQuotaAlertAuthorization(requestIfNeeded: Bool) {
        notificationCenter.getNotificationSettings { [weak self] settings in
            let authorizationStatus = settings.authorizationStatus.rawValue
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch UNAuthorizationStatus(rawValue: authorizationStatus) {
                case .authorized, .provisional, .ephemeral:
                    self.setQuotaAlertsEnabled(true)
                case .notDetermined where requestIfNeeded:
                    self.requestQuotaAlertAuthorization()
                case .denied:
                    self.setQuotaAlertsEnabled(false, error: AppText.notificationPermissionDenied)
                case .notDetermined:
                    self.setQuotaAlertsEnabled(false)
                case .some(_), nil:
                    self.setQuotaAlertsEnabled(false, error: AppText.notificationPermissionDenied)
                }
            }
        }
    }

    private func requestQuotaAlertAuthorization() {
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.setQuotaAlertsEnabled(false, error: Self.normalizedErrorText(error))
                } else if granted {
                    self.setQuotaAlertsEnabled(true)
                } else {
                    self.setQuotaAlertsEnabled(false, error: AppText.notificationPermissionDenied)
                }
            }
        }
    }

    private func setQuotaAlertsEnabled(_ enabled: Bool, error: String? = nil) {
        QuotaAlertPreferences.setEnabled(enabled)
        quotaAlertsAuthorized = enabled
        currentNotificationError = error
        preferencesView.updateQuotaAlerts(enabled: enabled)
        updateCombinedError()
        if enabled {
            refreshRateLimits()
        }
    }

    private func showAutoLaunchError(_ error: Error) {
        currentAutoLaunchError = Self.errorToolTip(error)
        updateCombinedError()
    }

    private func synchronizeAccount() {
        let identity = CodexBackend.currentRefreshIdentity()
        guard identity != refreshCoordinator.accountIdentity else { return }
        for ticket in refreshCoordinator.changeAccount(to: identity, now: Date()) { refreshOperations[ticket.id]?.cancel() }
        currentAccountContext = nil
        currentWeeklyWindow = nil
        currentQuotaSampleAt = nil
        currentCredits = nil
        currentResetCredits = nil
        currentResetAvailableCount = nil
        currentWeeklyRemaining = nil
        currentQuotaForecast = nil
        currentLocalUsage = nil
        currentQuotaMonitorError = nil
        renderRefreshState()
    }

    private func refreshRateLimits(reason: RefreshReason = .manual) {
        synchronizeAccount()
        guard !suspended, let ticket = refreshCoordinator.request(.official, reason: reason, now: Date()) else { return }
        let cancellation = RefreshCancellation(deadline: ticket.deadline)
        refreshOperations[ticket.id] = cancellation
        let monitor = quotaMonitor
        let alertsEnabled = QuotaAlertPreferences.isEnabled && quotaAlertsAuthorized
        renderRefreshState()
        rateLimitsQueue.async { [weak self] in
            let result = Result { () throws -> (RateLimitUIUpdate, QuotaMonitorSnapshot?) in
                try cancellation.check()
                guard ticket.accountIdentity == CodexBackend.currentRefreshIdentity() else { throw RuntimeError("Account changed.") }
                let update = RateLimitUIUpdate(try CodexBackend.readRateLimits(cancellation: cancellation))
                try cancellation.check()
                guard ticket.accountIdentity == CodexBackend.currentRefreshIdentity() else { throw RuntimeError("Account changed.") }
                let history = update.weekly.map { monitor.update(window: $0, alertsEnabled: alertsEnabled, accountContext: update.accountContext) }
                return (update, history)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.synchronizeAccount()
                let outcomes: [RefreshSource: RefreshOutcome]
                switch result {
                case .success(let value): outcomes = value.0.outcomes
                case .failure(let error): outcomes = Dictionary(uniqueKeysWithValues: RefreshLane.official.sources.map { ($0, RefreshOutcome(.failed, error: Self.normalizedErrorText(error))) })
                }
                let changedContext: Bool
                if case .success(let value) = result {
                    changedContext = self.currentAccountContext != nil && self.currentAccountContext != value.0.accountContext
                } else { changedContext = false }
                let accepted = self.refreshCoordinator.complete(ticket, outcomes: outcomes, now: Date(), resetHistory: changedContext)
                self.refreshOperations.removeValue(forKey: ticket.id)
                if accepted, case .success(let value) = result { self.applyRateLimits(value.0, monitor: value.1) }
                self.renderRefreshState()
                self.refreshRateLimits(reason: .timer)
            }
        }
    }

    private func refreshLocalUsage(reason: RefreshReason = .manual) {
        synchronizeAccount()
        guard !suspended, let ticket = refreshCoordinator.request(.local, reason: reason, now: Date()) else { return }
        let cancellation = RefreshCancellation(deadline: ticket.deadline)
        refreshOperations[ticket.id] = cancellation
        let weeklyWindow = currentWeeklyWindow
        let accountContext = currentAccountContext
        let quotaSampleAt = currentQuotaSampleAt
        renderRefreshState()
        localUsageQueue.async { [weak self] in
            let result = Result {
                try cancellation.check()
                guard ticket.accountIdentity == CodexBackend.currentRefreshIdentity() else { throw RuntimeError("Account changed.") }
                return try CodexBackend.readLocalTokenUsage(weeklyWindow: weeklyWindow, accountContext: accountContext,
                    rebuild: ticket.rebuild, quotaSampleAt: quotaSampleAt, cancellation: cancellation)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.synchronizeAccount()
                let outcome: RefreshOutcome
                switch result {
                case .success(let value): outcome = RefreshOutcome.local(value)
                case .failure(let error): outcome = RefreshOutcome(.failed, error: Self.normalizedErrorText(error))
                }
                let accepted = self.refreshCoordinator.complete(ticket, outcomes: [.localUsage: outcome], now: Date())
                self.refreshOperations.removeValue(forKey: ticket.id)
                if accepted, outcome.phase != .failed, case .success(let value) = result { self.currentLocalUsage = value }
                self.renderRefreshState()
                self.refreshLocalUsage(reason: .timer)
            }
        }
    }

    private func applyRateLimits(_ update: RateLimitUIUpdate, monitor: QuotaMonitorSnapshot?) {
        guard update.error == nil else { return }
        let previousContext = currentAccountContext
        let previousWindow = currentWeeklyWindow.flatMap(QuotaWindowID.init)?.rawValue
        let previousSampleAt = currentQuotaSampleAt
        if previousContext != update.accountContext {
            if let ticket = refreshCoordinator.invalidate(.local, now: Date(), clear: true) { refreshOperations[ticket.id]?.cancel() }
            currentLocalUsage = nil
            currentResetCredits = nil
            currentResetAvailableCount = nil
        }
        currentAccountContext = update.accountContext
        currentQuotaSampleAt = update.sampledAt
        currentWeeklyWindow = update.weekly
        currentWeeklyRemaining = update.weekly?.remainingPercent
        currentCredits = update.credits
        if update.outcomes[.credits]?.phase == .unavailable { currentCredits = nil }
        if update.outcomes[.resetCredits]?.phase != .failed {
            currentResetCredits = update.resetCredits
            currentResetAvailableCount = update.resetCredits?.availableCount
        }
        currentQuotaForecast = monitor?.forecast
        currentQuotaMonitorError = monitor?.persistenceError
        for alert in monitor?.alerts ?? [] { deliverQuotaAlert(alert) }
        if previousContext != currentAccountContext || previousWindow != currentWeeklyWindow.flatMap(QuotaWindowID.init)?.rawValue || previousSampleAt != currentQuotaSampleAt {
            refreshLocalUsage(reason: .quotaChanged)
        }
    }

    private func deliverQuotaAlert(_ event: QuotaAlertEvent) {
        let content = UNMutableNotificationContent()
        content.title = AppText.quotaAlertTitle(event)
        content.body = AppText.quotaAlertBody(event)
        content.sound = .default
        content.threadIdentifier = "quota-alerts"
        let request = UNNotificationRequest(identifier: event.identifier, content: content, trigger: nil)
        notificationCenter.add(request) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentNotificationError = error.map(Self.normalizedErrorText)
                self.updateCombinedError()
            }
        }
    }

    private func renderRefreshState() {
        let freshness = refreshCoordinator.snapshot(now: Date())
        let quotaOld = freshness.quota.isStale || freshness.quota.error != nil
        let localOld = freshness.localUsage.isStale || freshness.localUsage.error != nil
        accountItem.title = AppText.accountSource(currentAccountContext)
        accountItem.toolTip = AppText.accountSourceDetail(currentAccountContext)
        updateStatusImage(currentWeeklyRemaining.map { "W \($0)%" } ?? "W --", reset: currentWeeklyWindow?.resetDate.map(AppText.statusBarResetDate))
        statusItem.button?.alphaValue = quotaOld ? 0.55 : 1
        tokenStatusItem.button?.alphaValue = localOld ? 0.55 : 1
        let forecast = quotaOld ? nil : currentQuotaForecast
        let cost = quotaOld || localOld ? nil : matchingWeeklyQuotaCost(for: currentWeeklyWindow)
        rateLimitsView.update(weekly: currentWeeklyWindow, forecast: forecast, weeklyQuotaCost: cost, credits: currentCredits, freshness: freshness)
        resetCreditsView.update(currentResetCredits, freshness: freshness.resetCredits)
        localUsagePanelView.update(currentLocalUsage, freshness: freshness.localUsage)
        statusItem.button?.toolTip = AppText.rateLimitTooltip(
            weekly: currentWeeklyRemaining.map { "\($0)%" } ?? "--", resetCount: currentResetAvailableCount,
            forecast: forecast, weeklyQuotaCost: cost) + "\n" + AppText.officialCreditsBalance(currentCredits)
            + "\n" + AppText.refreshDetails(freshness)
        let consumption = currentLocalUsage?.display?.consumptionLabel ?? AppText.consumption(nil)
        let cacheHit = AppText.cacheHit(formatPercent(currentLocalUsage?.cacheHitPercent))
        tokenStatusItem.button?.image = makeStatusImage(top: consumption, bottom: cacheHit)
        tokenStatusItem.button?.toolTip = [currentLocalUsage?.display?.estimatedCostLabel,
            currentLocalUsage?.display?.estimatedCreditsLabel, currentLocalUsage?.display?.pricingCoverageLabel,
            AppText.unpricedUsageDetails(currentLocalUsage?.unpricedUsage), AppText.pricingDetails(currentLocalUsage?.pricing),
            currentLocalUsage.map(AppText.scanDetails), AppText.refreshDetails(freshness)].compactMap { $0 }.joined(separator: "\n")
        updateCombinedError()
    }

    private func matchingWeeklyQuotaCost(for window: RateLimitWindow?) -> WeeklyQuotaCostEstimate? {
        guard let resetDate = window?.resetDate,
              let estimate = currentLocalUsage?.weeklyQuotaCost,
              let scope = currentAccountContext?.scopeKey,
              estimate.accountScopeKey == scope
        else {
            return nil
        }
        return estimate.windowEndIso == ISO8601DateFormatter().string(from: resetDate) ? estimate : nil
    }

    private func updateCombinedError() {
        let freshness = refreshCoordinator.snapshot(now: Date())
        var details = RefreshSource.allCases.compactMap { source in
            freshness[source].error.map { "\(AppText.refreshSourceName(source)): \($0)" }
        }
        if let error = currentAutoLaunchError { details.append("\(AppText.autoLaunchFailure): \(error)") }
        if let quotaMonitorError = currentQuotaMonitorError, !quotaMonitorError.isEmpty {
            details.append("\(AppText.quotaForecastErrorLabel): \(quotaMonitorError)")
        }
        if let notificationError = currentNotificationError, !notificationError.isEmpty {
            details.append("\(AppText.quotaAlertsErrorLabel): \(notificationError)")
        }

        guard !details.isEmpty else {
            errorItem.title = ""
            errorItem.toolTip = nil
            errorItem.isHidden = true
            lastLoggedErrorDetails = nil
            return
        }

        let detailText = details.joined(separator: "\n")
        errorItem.title = AppText.partialRefreshFailure
        errorItem.toolTip = detailText
        errorItem.isHidden = false
        if detailText != lastLoggedErrorDetails {
            lastLoggedErrorDetails = detailText
            Self.appendLog("partial refresh failure: \(details.joined(separator: " | "))")
        }
    }

    private static func errorToolTip(_ error: Error) -> String {
        let detail = normalizedErrorText(error)
        guard detail.count > 1200 else { return detail }
        let endIndex = detail.index(detail.startIndex, offsetBy: 1200)
        return "\(detail[..<endIndex])..."
    }

    private static func normalizedErrorText(_ error: Error) -> String {
        let lines = error.localizedDescription
            .replacingOccurrences(of: "\t", with: " ")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    private func updateStatusImage(_ text: String, reset: String? = nil) {
        guard let button = statusItem.button else { return }
        // A nil tint lets AppKit choose a contrasting foreground for the current menu bar appearance.
        button.contentTintColor = nil
        button.image = makeStatusImage(top: text, bottom: reset, centerBottom: reset != nil, fontSize: 10)
    }

    nonisolated private static func appendLog(_ message: String) {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Logs")
            .appendingPathComponent("Codex Rate Limits Bar.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(timestamp) \(message)\n".data(using: .utf8) else { return }

        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: logURL, options: .atomic)
            }
        } catch {
            // Logging must never break refresh.
        }
    }

    private func formatPercent(_ percent: Double?) -> String {
        guard let percent else { return "--" }
        return String(format: "%.1f%%", percent)
    }

    private func splitStatusLine(_ text: String) -> (title: String, value: String) {
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if parts.count == 2 {
            return (String(parts[0]), String(parts[1]))
        }
        return ("", text)
    }

    private func makeStatusImage(
        top: String,
        bottom: String? = nil,
        centerBottom: Bool = false,
        fontSize: CGFloat = 11
    ) -> NSImage {
        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.alignment = .right
        let valueParagraph = NSMutableParagraphStyle()
        valueParagraph.alignment = .left
        let centeredParagraph = NSMutableParagraphStyle()
        centeredParagraph.alignment = .center
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: titleParagraph,
        ]
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: valueParagraph,
        ]
        let centeredAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: centeredParagraph,
        ]
        let rawLines = [top, bottom].compactMap { $0 }
        let lines = rawLines.map { splitStatusLine($0) }
        let columnLines = centerBottom && lines.count > 1 ? [lines[0]] : lines
        let titleWidth = ceil(columnLines.map {
            NSString(string: $0.title).size(withAttributes: titleAttributes).width
        }.max() ?? 0)
        let valueWidth = ceil(columnLines.map {
            NSString(string: $0.value).size(withAttributes: valueAttributes).width
        }.max() ?? 0)
        let gap: CGFloat = 7
        let horizontalPadding: CGFloat = 4
        let columnContentWidth = titleWidth + gap + valueWidth
        let centeredBottomWidth = centerBottom && rawLines.count > 1
            ? ceil(NSString(string: rawLines[1]).size(withAttributes: centeredAttributes).width)
            : 0
        let contentWidth = max(columnContentWidth, centeredBottomWidth)
        let size = NSSize(width: max(58, contentWidth + horizontalPadding * 2), height: 28)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let originX = floor((size.width - columnContentWidth) / 2)
        let titleRect = NSRect(x: originX, y: 0, width: titleWidth, height: 12)
        let valueRect = NSRect(x: originX + titleWidth + gap, y: 0, width: valueWidth, height: 12)
        for (index, line) in lines.enumerated() {
            let y: CGFloat = lines.count == 1 ? 8.5 : (index == 0 ? 14.5 : 2.5)
            if centerBottom && index == 1 {
                let centeredRect = NSRect(x: 0, y: y, width: size.width, height: 12)
                NSString(string: rawLines[index]).draw(in: centeredRect, withAttributes: centeredAttributes)
            } else {
                NSString(string: line.title).draw(in: titleRect.offsetBy(dx: 0, dy: y), withAttributes: titleAttributes)
                NSString(string: line.value).draw(in: valueRect.offsetBy(dx: 0, dy: y), withAttributes: valueAttributes)
            }
        }
        image.isTemplate = true
        return image
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

}

let commandLineArguments = Array(CommandLine.arguments.dropFirst())
if CodexCommandLine.isCLIInvocation(commandLineArguments) {
    exit(CodexCommandLine.run(arguments: commandLineArguments))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        guard let copy = self.copy() as? NSImage else { return self }
        copy.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: copy.size)
        rect.fill(using: .sourceIn)
        copy.unlockFocus()
        return copy
    }
}
