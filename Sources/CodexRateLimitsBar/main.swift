import AppKit
import Darwin
import Foundation

struct RateLimitWindow: Codable {
    let usedPercent: Int
    let remainingPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Int?
    let resetsAtIso: String?

    var resetDate: Date? {
        if let resetsAt {
            return Date(timeIntervalSince1970: TimeInterval(resetsAt))
        }
        guard let resetsAtIso else { return nil }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: resetsAtIso) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: resetsAtIso)
    }
}

struct CreditsSnapshot: Codable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

struct RateLimitSnapshot: Codable {
    let limitId: String?
    let limitName: String?
    let planType: String?
    let rateLimitReachedType: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: CreditsSnapshot?
    let individualLimit: JSONValue?

    var weeklyWindow: RateLimitWindow? {
        if primary?.windowDurationMins == 10_080 {
            return primary
        }
        if secondary?.windowDurationMins == 10_080 {
            return secondary
        }
        return nil
    }
}

struct RateLimitDisplay: Codable {
    let primaryLabel: String?
    let secondaryLabel: String?
    let primaryRemainingPercent: Int?
    let secondaryRemainingPercent: Int?
}

struct RateLimitPayload: Codable {
    let fetchedAtIso: String
    let rateLimits: RateLimitSnapshot?
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
    let display: RateLimitDisplay?
    let resetCredits: ResetCreditsSnapshot?
    let localUsage: LocalUsageSnapshot?
    let rateLimitError: String?
    let localUsageError: String?
    let usage: JSONValue?
}

struct ResetCreditItem: Codable {
    let id: String?
    let resetType: String?
    let typeLabel: String?
    let status: String?
    let statusLabel: String?
    let createdAtIso: String?
    let expiresAtIso: String?
    let createdAtLabel: String?
    let expiresAtLabel: String?
    let createdAtShortLabel: String?
    let expiresAtShortLabel: String?
}

struct ResetCreditsDisplay: Codable {
    let summaryLabel: String?
    let categoryLabel: String?
    let detailLabels: [String]?
}

struct ResetCreditsSnapshot: Codable {
    let fetchedAtIso: String
    let availableCount: Int?
    let credits: [ResetCreditItem]
    let error: String?
    let display: ResetCreditsDisplay?
}

struct LocalUsageDisplay: Codable {
    let consumptionLabel: String?
    let cacheHitLabel: String?
}

struct LocalUsageTopFile: Codable {
    let file: String
    let eventCount: Int
    let duplicateEventCount: Int
    let importedEventCount: Int
    let regressionEventCount: Int
    let primarySessionId: String?
    let totalTokens: Int64
    let lastEventAtIso: String?
}

struct LocalUsageSnapshot: Codable {
    let fetchedAtIso: String
    let source: String?
    let timezone: String?
    let localDate: String
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64
    let cacheHitPercent: Double?
    let eventCount: Int
    let duplicateEventCount: Int
    let importedEventCount: Int
    let regressionEventCount: Int
    let filesScanned: Int
    let filesWithEvents: Int
    let parseErrorCount: Int
    let error: String?
    let topFiles: [LocalUsageTopFile]?
    let display: LocalUsageDisplay?
}

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

    func update(weekly: RateLimitWindow?) {
        cardView.update(weekly: weekly)
    }
}

class RateLimitsDrawingView: NSView {
    private var weekly: RateLimitWindow?

    override var isFlipped: Bool {
        true
    }

    func update(weekly: RateLimitWindow?) {
        self.weekly = weekly
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let labelColor = NSColor.labelColor
        let secondaryColor = NSColor.secondaryLabelColor

        drawSymbol("chart.bar.fill", in: NSRect(x: 12, y: 12, width: 14, height: 14), color: secondaryColor)
        drawText(AppText.usageTitle, in: NSRect(x: 32, y: 10, width: 200, height: 18), font: .systemFont(ofSize: 12, weight: .bold), color: labelColor)

        drawQuotaRow(label: AppText.weeklyLimit, window: weekly, y: 36)
    }

    private func drawQuotaRow(label: String, window: RateLimitWindow?, y: CGFloat) {
        let remaining = window?.remainingPercent
        let colors = gradientColors(for: remaining)
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
    }

    private func gradientColors(for remaining: Int?) -> (start: NSColor, end: NSColor) {
        guard let remaining else {
            return (NSColor.tertiaryLabelColor, NSColor.tertiaryLabelColor)
        }
        if remaining < 10 {
            return (NSColor(red: 0.92, green: 0.30, blue: 0.26, alpha: 1.0), NSColor(red: 0.82, green: 0.20, blue: 0.16, alpha: 1.0))
        }
        if remaining < 25 {
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

    func update(weekly: RateLimitWindow?) {
        drawingView.update(weekly: weekly)
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

    func update(_ snapshot: ResetCreditsSnapshot?) {
        let h = Self.height(for: snapshot)
        setFrameSize(NSSize(width: frame.width, height: h))
        cardView.frame = NSRect(x: 16, y: 4, width: bounds.width - 32, height: h - 8)
        cardView.update(snapshot)
    }

    static func height(for snapshot: ResetCreditsSnapshot?) -> CGFloat {
        let rows = min(snapshot?.display?.detailLabels?.count ?? 0, 4)
        if rows == 0 {
            return 66
        }
        return CGFloat(50 + rows * 18)
    }
}

class ResetCreditsDrawingView: NSView {
    private var snapshot: ResetCreditsSnapshot?

    override var isFlipped: Bool {
        true
    }

    func update(_ snapshot: ResetCreditsSnapshot?) {
        self.snapshot = snapshot
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
        drawText(summary, in: NSRect(x: 120, y: 10, width: bounds.width - 132, height: 17), font: .systemFont(ofSize: 12, weight: .bold), color: accent, alignment: .right)

        let rows = Array((snapshot?.display?.detailLabels ?? []).prefix(4))
        if rows.isEmpty {
            drawText(AppText.noResetCredits, in: NSRect(x: 12, y: 34, width: bounds.width - 24, height: 16), font: .systemFont(ofSize: 10.5, weight: .regular), color: secondaryColor)
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

    func update(_ snapshot: ResetCreditsSnapshot?) {
        drawingView.update(snapshot)
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

    func configure(
        autoLaunchTarget: AnyObject?,
        autoLaunchAction: Selector,
        localUsageStatusItemTarget: AnyObject?,
        localUsageStatusItemAction: Selector
    ) {
        cardView.configure(
            autoLaunchTarget: autoLaunchTarget,
            autoLaunchAction: autoLaunchAction,
            localUsageStatusItemTarget: localUsageStatusItemTarget,
            localUsageStatusItemAction: localUsageStatusItemAction
        )
    }

    func updateAutoLaunch(enabled: Bool) {
        cardView.updateAutoLaunch(enabled: enabled)
    }

    func updateLocalUsageStatusItem(visible: Bool) {
        cardView.updateLocalUsageStatusItem(visible: visible)
    }
}

class PreferencesCardView: NSVisualEffectView {
    private let autoLaunchCheckbox = NSButton(checkboxWithTitle: AppText.launchAtLogin, target: nil, action: nil)
    private let localUsageStatusItemCheckbox = NSButton(checkboxWithTitle: AppText.showLocalUsageStatusItem, target: nil, action: nil)
    private let separator = NSBox()

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

        for checkbox in [autoLaunchCheckbox, localUsageStatusItemCheckbox] {
            checkbox.font = .systemFont(ofSize: 12, weight: .semibold)
            checkbox.setButtonType(.switch)
            addSubview(checkbox)
        }

        separator.boxType = .separator
        addSubview(separator)
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

    func configure(
        autoLaunchTarget: AnyObject?,
        autoLaunchAction: Selector,
        localUsageStatusItemTarget: AnyObject?,
        localUsageStatusItemAction: Selector
    ) {
        autoLaunchCheckbox.target = autoLaunchTarget
        autoLaunchCheckbox.action = autoLaunchAction
        localUsageStatusItemCheckbox.target = localUsageStatusItemTarget
        localUsageStatusItemCheckbox.action = localUsageStatusItemAction
    }

    func updateAutoLaunch(enabled: Bool) {
        autoLaunchCheckbox.state = enabled ? .on : .off
    }

    func updateLocalUsageStatusItem(visible: Bool) {
        localUsageStatusItemCheckbox.state = visible ? .on : .off
    }

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()
        let rowHeight = floor(bounds.height / 2)
        let checkboxY = floor((rowHeight - 20) / 2) - 3
        autoLaunchCheckbox.frame = NSRect(x: 12, y: checkboxY, width: bounds.width - 24, height: 26)
        localUsageStatusItemCheckbox.frame = NSRect(x: 12, y: rowHeight + checkboxY, width: bounds.width - 24, height: 26)
        separator.frame = NSRect(x: 12, y: rowHeight, width: bounds.width - 24, height: 1)
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

    func update(_ snapshot: LocalUsageSnapshot) {
        cardView.update(snapshot)
    }
}

class LocalUsageDrawingView: NSView {
    private var snapshot: LocalUsageSnapshot?

    override var isFlipped: Bool {
        true
    }

    func update(_ snapshot: LocalUsageSnapshot) {
        self.snapshot = snapshot
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let labelColor = NSColor.labelColor
        let secondaryColor = NSColor.secondaryLabelColor

        let blue = NSColor.systemBlue
        let purple = NSColor.systemPurple
        let green = NSColor.systemGreen

        let subCardFill = isDark ? NSColor.white.withAlphaComponent(0.055) : NSColor.black.withAlphaComponent(0.035)
        let subCardStroke = isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.05)

        let totalTokens = snapshot?.totalTokens ?? 0
        let inputTokens = snapshot?.inputTokens ?? 0
        let cachedInputTokens = snapshot?.cachedInputTokens ?? 0
        let newInputTokens = max(0, inputTokens - cachedInputTokens)
        let outputTokens = snapshot?.outputTokens ?? 0
        let eventCount = snapshot?.eventCount ?? 0
        let cacheHitPercent = snapshot?.cacheHitPercent

        drawSymbol("cpu.fill", in: NSRect(x: 12, y: 12, width: 14, height: 14), color: secondaryColor)
        drawText(AppText.localUsageTitle, in: NSRect(x: 32, y: 10, width: 250, height: 18), font: .systemFont(ofSize: 12, weight: .bold), color: labelColor)

        let rawTotal = formatRawNumber(totalTokens)
        let rawFont = NSFont.monospacedDigitSystemFont(ofSize: 32, weight: .bold)
        let rawWidth = ceil(NSString(string: rawTotal).size(withAttributes: [.font: rawFont]).width)
        drawText(rawTotal, in: NSRect(x: 12, y: 32, width: min(rawWidth + 4, 250), height: 42), font: rawFont, color: labelColor)

        let requestRect = NSRect(x: bounds.width - 120, y: 12, width: 108, height: 58)
        drawSubCard(requestRect, fill: subCardFill, stroke: subCardStroke)
        drawText(AppText.totalRequests, in: NSRect(x: requestRect.minX + 10, y: requestRect.minY + 6, width: requestRect.width - 20, height: 16), font: .systemFont(ofSize: 10.5, weight: .semibold), color: secondaryColor)
        drawText(formatRawNumber(Int64(eventCount)), in: NSRect(x: requestRect.minX + 10, y: requestRect.minY + 24, width: requestRect.width - 20, height: 24), font: .monospacedDigitSystemFont(ofSize: 18, weight: .bold), color: labelColor)

        let padding: CGFloat = 12
        let gap: CGFloat = 8
        let gridWidth = bounds.width - padding * 2
        let cardWidth = floor((gridWidth - gap) / 2)
        let cardHeight: CGFloat = 52

        let rowOneY: CGFloat = 84
        let rowTwoY: CGFloat = 144

        let rect1 = NSRect(x: padding, y: rowOneY, width: cardWidth, height: cardHeight)
        drawMetricCard(rect1, title: AppText.newInput, value: TokenAmountFormatter.compact(newInputTokens, maximumFractionDigits: 1), tint: blue, fill: subCardFill, stroke: subCardStroke)

        let rect2 = NSRect(x: padding + cardWidth + gap, y: rowOneY, width: cardWidth, height: cardHeight)
        drawMetricCard(rect2, title: AppText.output, value: TokenAmountFormatter.compact(outputTokens, maximumFractionDigits: 1), tint: purple, fill: subCardFill, stroke: subCardStroke)

        let rect3 = NSRect(x: padding, y: rowTwoY, width: cardWidth, height: cardHeight)
        drawMetricCard(rect3, title: AppText.hit, value: TokenAmountFormatter.compact(cachedInputTokens, maximumFractionDigits: 2), tint: green, fill: subCardFill, stroke: subCardStroke)

        let rect4 = NSRect(x: padding + cardWidth + gap, y: rowTwoY, width: cardWidth, height: cardHeight)
        drawCacheHitCard(rect4, percent: cacheHitPercent, fill: subCardFill, stroke: subCardStroke, tint: green)
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

    func update(_ snapshot: LocalUsageSnapshot) {
        drawingView.update(snapshot)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let tokenStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let rateLimitsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let rateLimitsView = RateLimitsMenuView(frame: NSRect(x: 0, y: 0, width: 440, height: 92))
    private let resetCreditsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let resetCreditsView = ResetCreditsMenuView(frame: NSRect(x: 0, y: 0, width: 440, height: 86))
    private let localUsageHeaderItem = NSMenuItem(title: "Local Today", action: nil, keyEquivalent: "")
    private let localConsumptionItem = NSMenuItem(title: "消耗 --", action: nil, keyEquivalent: "")
    private let localCacheHitItem = NSMenuItem(title: "命中 --", action: nil, keyEquivalent: "")
    private let localUsageDetailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let localUsagePanelItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let localUsagePanelView = LocalUsageMenuView(frame: NSRect(x: 0, y: 0, width: 440, height: 224))
    private let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let preferencesItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let preferencesView = PreferencesMenuView(frame: NSRect(x: 0, y: 0, width: 440, height: 72))
    private var rateLimitsTimer: Timer?
    private var localUsageTimer: Timer?
    private var resetCreditsTimer: Timer?
    private var isRefreshing = false
    private var isRefreshingRateLimits = false
    private var isRefreshingLocalUsage = false
    private var isRefreshingResetCredits = false
    private var currentWeeklyRemaining: Int?
    private var currentResetAvailableCount: Int?
    private var currentRateLimitError: String?
    private var currentResetCreditsError: String?
    private var currentLocalUsageError: String?
    private var lastLoggedErrorDetails: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("Keep the Codex rate limits status item available")
        setupStatusItem()
        setupTokenStatusItem()
        setupMenu()
        configureAutoLaunch()
        configureLocalUsageStatusItemVisibility()
        refresh()
        localUsageTimer = Timer.scheduledTimer(timeInterval: 30, target: self, selector: #selector(timerRefreshLocalUsage), userInfo: nil, repeats: true)
        rateLimitsTimer = Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(timerRefreshRateLimits), userInfo: nil, repeats: true)
        resetCreditsTimer = Timer.scheduledTimer(timeInterval: 600, target: self, selector: #selector(timerRefreshResetCredits), userInfo: nil, repeats: true)
    }

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        updateStatusImage("W --", style: .waiting)
        button.toolTip = AppText.rateLimitStatusTooltip
        statusItem.menu = menu
    }

    private func setupTokenStatusItem() {
        guard let button = tokenStatusItem.button else { return }
        button.imagePosition = .imageOnly
        button.image = makeStatusImage(top: AppText.consumption(nil), bottom: AppText.cacheHit(nil))
        button.toolTip = AppText.localUsageStatusTooltip
        tokenStatusItem.menu = menu
    }

    private func setupMenu() {
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
            localUsageStatusItemAction: #selector(toggleLocalUsageStatusItemVisibility)
        )
        updateAutoLaunchMenu(enabled: AutoLaunchManager.preferredEnabled)
        preferencesView.updateLocalUsageStatusItem(visible: StatusItemPreferences.isLocalUsageStatusItemVisible)

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

        let quitItem = NSMenuItem(title: AppText.quit, action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func refreshFromMenu() {
        refresh()
    }

    @objc private func timerRefreshRateLimits() {
        refreshRateLimits()
    }

    @objc private func timerRefreshLocalUsage() {
        refreshLocalUsage()
    }

    @objc private func timerRefreshResetCredits() {
        refreshResetCredits()
    }

    @objc private func toggleAutoLaunch() {
        setAutoLaunch(enabled: preferencesView.isAutoLaunchChecked)
    }

    @objc private func toggleLocalUsageStatusItemVisibility() {
        setLocalUsageStatusItemVisible(preferencesView.isLocalUsageStatusItemChecked)
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
            if errorItem.title == AppText.autoLaunchFailure {
                errorItem.title = ""
                errorItem.isHidden = true
            }
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

    private func showAutoLaunchError(_ error: Error) {
        errorItem.title = AppText.autoLaunchFailure
        errorItem.toolTip = Self.errorToolTip(error)
        errorItem.isHidden = false
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.fetchStatus()
            DispatchQueue.main.async {
                self?.isRefreshing = false
                switch result {
                case .success(let payload):
                    self?.apply(payload)
                case .failure(let error):
                    self?.apply(error)
                }
            }
        }
    }

    private func refreshRateLimits() {
        guard !isRefreshing, !isRefreshingRateLimits else { return }
        isRefreshingRateLimits = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.fetchRateLimits()
            DispatchQueue.main.async {
                self?.isRefreshingRateLimits = false
                switch result {
                case .success(let payload):
                    self?.applyRateLimits(payload)
                    self?.updateCombinedError()
                case .failure(let error):
                    self?.applyRateLimitsError(error)
                }
            }
        }
    }

    private func refreshLocalUsage() {
        guard !isRefreshing, !isRefreshingLocalUsage else { return }
        isRefreshingLocalUsage = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.fetchLocalUsage()
            DispatchQueue.main.async {
                self?.isRefreshingLocalUsage = false
                switch result {
                case .success(let localUsage):
                    self?.currentLocalUsageError = localUsage.error
                    self?.apply(localUsage)
                    self?.updateCombinedError()
                case .failure(let error):
                    self?.applyLocalUsageError(error)
                }
            }
        }
    }

    private func refreshResetCredits() {
        guard !isRefreshing, !isRefreshingResetCredits else { return }
        isRefreshingResetCredits = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.fetchResetCredits()
            DispatchQueue.main.async {
                self?.isRefreshingResetCredits = false
                switch result {
                case .success(let resetCredits):
                    self?.apply(resetCredits)
                    self?.updateCombinedError()
                case .failure(let error):
                    self?.applyResetCreditsError(error)
                }
            }
        }
    }

    private func apply(_ payload: RateLimitPayload) {
        applyRateLimits(payload)
        if let resetCredits = payload.resetCredits {
            apply(resetCredits)
        }
        if let localUsage = payload.localUsage {
            apply(localUsage)
        }
        currentRateLimitError = payload.rateLimitError
        currentResetCreditsError = payload.resetCredits?.error
        currentLocalUsageError = payload.localUsageError
        updateCombinedError()
    }

    private func applyRateLimits(_ payload: RateLimitPayload) {
        let weekly = payload.rateLimits?.weeklyWindow
        let weeklyRemaining = weekly?.remainingPercent
        currentWeeklyRemaining = weeklyRemaining
        currentRateLimitError = payload.rateLimitError
        let status = weeklyRemaining.map { "W \($0)%" } ?? "W --"
        let reset = weekly?.resetDate.map(AppText.statusBarResetDate)
        updateStatusImage(status, reset: reset, style: style(for: weeklyRemaining))

        rateLimitsView.update(weekly: weekly)
        updateRateLimitTooltip()
    }

    private func apply(_ resetCredits: ResetCreditsSnapshot) {
        currentResetAvailableCount = resetCredits.availableCount
        currentResetCreditsError = resetCredits.error
        resetCreditsView.update(resetCredits)
        updateRateLimitTooltip()
    }

    private func apply(_ localUsage: LocalUsageSnapshot) {
        let consumption = localUsage.display?.consumptionLabel ?? AppText.consumption(TokenAmountFormatter.compact(localUsage.totalTokens))
        let cacheHit = AppText.cacheHit(formatPercent(localUsage.cacheHitPercent))
        tokenStatusItem.button?.image = makeStatusImage(top: consumption, bottom: cacheHit)
        tokenStatusItem.button?.toolTip = AppText.localUsageTooltip(tokens: TokenAmountFormatter.compact(localUsage.totalTokens), cacheHit: formatPercent(localUsage.cacheHitPercent))

        localConsumptionItem.title = consumption
        localCacheHitItem.title = cacheHit
        localUsageDetailItem.title = AppText.localUsageDetail(events: localUsage.eventCount, filesWithEvents: localUsage.filesWithEvents, filesScanned: localUsage.filesScanned)
        localUsageDetailItem.isHidden = true
        localUsagePanelView.update(localUsage)
    }

    private func applyRateLimitsError(_ error: Error) {
        currentRateLimitError = Self.normalizedErrorText(error)
        statusItem.button?.toolTip = AppText.rateLimitRefreshFailedTooltip
        updateCombinedError()
        Self.appendLog("rate limit refresh failed: \(Self.normalizedErrorText(error))")
    }

    private func applyLocalUsageError(_ error: Error) {
        currentLocalUsageError = Self.normalizedErrorText(error)
        tokenStatusItem.button?.toolTip = AppText.localUsageRefreshFailedTooltip
        updateCombinedError()
        Self.appendLog("local usage refresh failed: \(Self.normalizedErrorText(error))")
    }

    private func applyResetCreditsError(_ error: Error) {
        currentResetCreditsError = Self.normalizedErrorText(error)
        updateRateLimitTooltip()
        updateCombinedError()
        Self.appendLog("reset credits refresh failed: \(Self.normalizedErrorText(error))")
    }

    private func updateRateLimitTooltip() {
        statusItem.button?.toolTip = AppText.rateLimitTooltip(
            weekly: currentWeeklyRemaining.map { "\($0)%" } ?? "--",
            resetCount: currentResetAvailableCount
        )
    }

    private func updateCombinedError() {
        var details: [String] = []
        if let rateLimitError = currentRateLimitError, !rateLimitError.isEmpty {
            details.append("\(AppText.rateLimitErrorLabel): \(rateLimitError)")
        }
        if let resetCreditsError = currentResetCreditsError, !resetCreditsError.isEmpty {
            details.append("\(AppText.resetCreditsTitle): \(resetCreditsError)")
        }
        if let localUsageError = currentLocalUsageError, !localUsageError.isEmpty {
            details.append("\(AppText.localUsageErrorLabel): \(localUsageError)")
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

    private func apply(_ error: Error) {
        errorItem.title = Self.refreshErrorTitle(error)
        errorItem.toolTip = Self.errorToolTip(error)
        errorItem.isHidden = false
        statusItem.button?.toolTip = AppText.rateLimitRefreshFailedTooltip
        tokenStatusItem.button?.toolTip = AppText.localUsageRefreshFailedTooltip
        Self.appendLog("refresh failed: \(Self.normalizedErrorText(error))")
    }

    private static func refreshErrorTitle(_ error: Error) -> String {
        let detail = normalizedErrorText(error)
        if detail.contains("account/rateLimits/read failed") {
            return AppText.refreshRateLimitUnavailable
        }
        if detail.contains("account/usage/read failed") {
            return AppText.refreshUsageUnavailable
        }
        if detail.localizedCaseInsensitiveContains("timed out") || detail.localizedCaseInsensitiveContains("timeout") {
            return AppText.refreshTimeout
        }
        return AppText.refreshStatusUnavailable
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

    private func updateStatusImage(_ text: String, reset: String? = nil, style: StatusStyle) {
        guard let button = statusItem.button else { return }
        button.image = makeStatusImage(top: text, bottom: reset, centerBottom: reset != nil, fontSize: 10)
        button.contentTintColor = statusTintColor(for: style)
    }

    nonisolated private static func fetchStatus() -> Result<RateLimitPayload, Error> {
        .success(CodexBackend.readStatus())
    }

    nonisolated private static func fetchRateLimits() -> Result<RateLimitPayload, Error> {
        Result { try CodexBackend.readRateLimits() }
    }

    nonisolated private static func fetchLocalUsage() -> Result<LocalUsageSnapshot, Error> {
        Result { try CodexBackend.readLocalTokenUsage() }
    }

    nonisolated private static func fetchResetCredits() -> Result<ResetCreditsSnapshot, Error> {
        Result { try CodexBackend.readResetCredits(soft: true) }
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

    private func style(for remaining: Int?) -> StatusStyle {
        let remaining = remaining ?? 100
        if remaining <= 10 { return .critical }
        if remaining <= 25 { return .warning }
        return .normal
    }

    private func statusTintColor(for style: StatusStyle) -> NSColor? {
        switch style {
        case .normal:
            return nil
        case .warning:
            return .systemOrange
        case .critical, .error:
            return .systemRed
        case .waiting:
            return nil
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

}

enum StatusStyle {
    case normal
    case warning
    case critical
    case waiting
    case error
}

struct RuntimeError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
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
