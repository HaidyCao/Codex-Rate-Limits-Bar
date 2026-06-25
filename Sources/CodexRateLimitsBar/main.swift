import AppKit
import Darwin
import Foundation

struct RateLimitWindow: Decodable {
    let usedPercent: Int
    let remainingPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Int?
    let resetsAtIso: String?
}

struct CreditsSnapshot: Decodable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

struct RateLimitSnapshot: Decodable {
    let limitId: String?
    let limitName: String?
    let planType: String?
    let rateLimitReachedType: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: CreditsSnapshot?
}

struct RateLimitPayload: Decodable {
    let fetchedAtIso: String
    let rateLimits: RateLimitSnapshot?
    let resetCredits: ResetCreditsSnapshot?
    let localUsage: LocalUsageSnapshot?
}

struct ResetCreditItem: Decodable {
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

struct ResetCreditsDisplay: Decodable {
    let summaryLabel: String?
    let categoryLabel: String?
    let detailLabels: [String]?
}

struct ResetCreditsSnapshot: Decodable {
    let fetchedAtIso: String
    let availableCount: Int?
    let credits: [ResetCreditItem]
    let error: String?
    let display: ResetCreditsDisplay?
}

struct LocalUsageDisplay: Decodable {
    let consumptionLabel: String?
    let cacheHitLabel: String?
}

struct LocalUsageSnapshot: Decodable {
    let fetchedAtIso: String
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
    let filesScanned: Int
    let filesWithEvents: Int
    let parseErrorCount: Int
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
        try runLaunchctl(["bootout", userDomain, plistURL.path], allowFailure: true)
        try runLaunchctl(["bootstrap", userDomain, plistURL.path])
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

final class ResetCreditsMenuView: NSView {
    private var snapshot: ResetCreditsSnapshot?

    func update(_ snapshot: ResetCreditsSnapshot?) {
        self.snapshot = snapshot
        setFrameSize(NSSize(width: frame.width, height: Self.height(for: snapshot)))
        needsDisplay = true
    }

    static func height(for snapshot: ResetCreditsSnapshot?) -> CGFloat {
        let rows = min(snapshot?.display?.detailLabels?.count ?? 0, 4)
        return rows == 0 ? 50 : CGFloat(52 + rows * 18)
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let primary = NSColor.labelColor
        let secondary = NSColor.secondaryLabelColor
        let tertiary = NSColor.tertiaryLabelColor
        let accent = (snapshot?.availableCount ?? 0) > 0 ? NSColor.systemOrange : tertiary

        drawText("重置券", in: NSRect(x: 16, y: 6, width: 56, height: 17), font: .systemFont(ofSize: 12, weight: .semibold), color: secondary)
        drawText(snapshot?.display?.summaryLabel ?? "可用次数：--", in: NSRect(x: 76, y: 6, width: bounds.width - 92, height: 17), font: .systemFont(ofSize: 12, weight: .bold), color: primary)

        let category = snapshot?.display?.categoryLabel ?? "Codex 速率限制重置"
        drawAccentLine(at: NSPoint(x: 16, y: 29), color: accent)
        drawText(category, in: NSRect(x: 44, y: 24, width: bounds.width - 60, height: 16), font: .systemFont(ofSize: 11, weight: .regular), color: tertiary)

        let rows = Array((snapshot?.display?.detailLabels ?? []).prefix(4))
        if rows.isEmpty {
            drawText("暂无可显示的重置券", in: NSRect(x: 16, y: 40, width: bounds.width - 32, height: 16), font: .systemFont(ofSize: 11, weight: .regular), color: tertiary)
            return
        }

        for (index, row) in rows.enumerated() {
            drawText(row, in: NSRect(x: 16, y: 43 + CGFloat(index * 18), width: bounds.width - 32, height: 16), font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: secondary)
        }
    }

    private func drawAccentLine(at point: NSPoint, color: NSColor) {
        color.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: point.x, y: point.y, width: 18, height: 2), xRadius: 1, yRadius: 1).fill()
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        NSString(string: text).draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }
}

final class AutoLaunchMenuView: NSView {
    private let sectionLabel = NSTextField(labelWithString: "启动")
    private let checkbox = NSButton(checkboxWithTitle: "在开机时启动", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override var isFlipped: Bool {
        true
    }

    var isChecked: Bool {
        checkbox.state == .on
    }

    func configure(target: AnyObject?, action: Selector) {
        checkbox.target = target
        checkbox.action = action
    }

    func update(enabled: Bool) {
        checkbox.state = enabled ? .on : .off
    }

    override func layout() {
        super.layout()
        sectionLabel.frame = NSRect(x: 16, y: 10, width: 56, height: 20)
        checkbox.frame = NSRect(x: 86, y: 5, width: bounds.width - 102, height: 28)
    }

    private func setup() {
        sectionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        sectionLabel.textColor = .secondaryLabelColor
        checkbox.font = .systemFont(ofSize: 14, weight: .semibold)
        checkbox.setButtonType(.switch)
        addSubview(sectionLabel)
        addSubview(checkbox)
    }
}

final class LocalUsageMenuView: NSView {
    private var snapshot: LocalUsageSnapshot?

    func update(_ snapshot: LocalUsageSnapshot) {
        self.snapshot = snapshot
        needsDisplay = true
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let primary = NSColor.labelColor
        let secondary = NSColor.secondaryLabelColor
        let tertiary = NSColor.tertiaryLabelColor
        let green = NSColor.systemGreen
        let blue = NSColor.systemBlue
        let purple = NSColor.systemPurple
        let cardFill = (isDark ? NSColor.white : NSColor.black).withAlphaComponent(isDark ? 0.055 : 0.035)
        let cardStroke = NSColor.separatorColor.withAlphaComponent(isDark ? 0.42 : 0.28)

        let totalTokens = snapshot?.totalTokens ?? 0
        let inputTokens = snapshot?.inputTokens ?? 0
        let cachedInputTokens = snapshot?.cachedInputTokens ?? 0
        let newInputTokens = max(0, inputTokens - cachedInputTokens)
        let outputTokens = snapshot?.outputTokens ?? 0
        let eventCount = snapshot?.eventCount ?? 0
        let cacheHitPercent = snapshot?.cacheHitPercent

        drawText("Codex · 真实消耗 Tokens", in: NSRect(x: 16, y: 12, width: 250, height: 18), font: .systemFont(ofSize: 12, weight: .semibold), color: secondary)
        let rawTotal = formatRawNumber(totalTokens)
        let rawFont = NSFont.monospacedDigitSystemFont(ofSize: 32, weight: .bold)
        let rawWidth = ceil(NSString(string: rawTotal).size(withAttributes: [.font: rawFont]).width)
        drawText(rawTotal, in: NSRect(x: 16, y: 36, width: min(rawWidth + 4, 285), height: 42), font: rawFont, color: primary)
        drawPill("≈ \(formatScaledNumber(totalTokens, maximumFractionDigits: 2))", at: NSPoint(x: min(24 + rawWidth, 300), y: 45), color: tertiary, fillColor: cardFill)

        let requestRect = NSRect(x: bounds.width - 126, y: 20, width: 110, height: 58)
        drawRoundedRect(requestRect, fill: cardFill, stroke: cardStroke, radius: 10)
        drawText("总请求数", in: requestRect.insetBy(dx: 12, dy: 9), font: .systemFont(ofSize: 11, weight: .semibold), color: secondary)
        drawText(formatRawNumber(Int64(eventCount)), in: NSRect(x: requestRect.minX + 12, y: requestRect.minY + 30, width: requestRect.width - 24, height: 22), font: .monospacedDigitSystemFont(ofSize: 18, weight: .bold), color: primary)

        let padding: CGFloat = 16
        let gap: CGFloat = 8
        let contentWidth = bounds.width - padding * 2
        let rowOneY: CGFloat = 92
        let rowTwoY: CGFloat = 158
        let cardHeight: CGFloat = 52
        let wideCardWidth = floor((contentWidth - gap) / 2)
        drawMetricCard(NSRect(x: padding, y: rowOneY, width: wideCardWidth, height: cardHeight), title: "新增输入", value: formatScaledNumber(newInputTokens, maximumFractionDigits: 1), tint: blue, fill: cardFill, stroke: cardStroke)
        drawMetricCard(NSRect(x: padding + wideCardWidth + gap, y: rowOneY, width: wideCardWidth, height: cardHeight), title: "Output", value: formatScaledNumber(outputTokens, maximumFractionDigits: 1), tint: purple, fill: cardFill, stroke: cardStroke)
        drawMetricCard(NSRect(x: padding, y: rowTwoY, width: wideCardWidth, height: cardHeight), title: "命中", value: formatScaledNumber(cachedInputTokens, maximumFractionDigits: 2), tint: green, fill: cardFill, stroke: cardStroke)
        drawCacheHitCard(NSRect(x: padding + wideCardWidth + gap, y: rowTwoY, width: wideCardWidth, height: cardHeight), percent: cacheHitPercent, fill: cardFill, stroke: cardStroke, tint: green)
    }

    private func drawMetricCard(_ rect: NSRect, title: String, value: String, tint: NSColor, fill: NSColor, stroke: NSColor) {
        drawRoundedRect(rect, fill: fill, stroke: stroke, radius: 10)
        drawText(title, in: NSRect(x: rect.minX + 12, y: rect.minY + 9, width: rect.width - 24, height: 17), font: .systemFont(ofSize: 12, weight: .semibold), color: NSColor.secondaryLabelColor)
        drawText(value, in: NSRect(x: rect.minX + 12, y: rect.minY + 29, width: rect.width - 24, height: 19), font: .monospacedDigitSystemFont(ofSize: 17, weight: .bold), color: NSColor.labelColor)
        drawAccentLine(in: rect, color: tint)
    }

    private func drawCacheHitCard(_ rect: NSRect, percent: Double?, fill: NSColor, stroke: NSColor, tint: NSColor) {
        drawRoundedRect(rect, fill: fill, stroke: stroke, radius: 10)
        drawText("缓存命中率", in: NSRect(x: rect.minX + 12, y: rect.minY + 9, width: rect.width - 92, height: 17), font: .systemFont(ofSize: 12, weight: .semibold), color: .secondaryLabelColor)
        drawText(formatPercent(percent), in: NSRect(x: rect.maxX - 86, y: rect.minY + 9, width: 74, height: 17), font: .monospacedDigitSystemFont(ofSize: 13, weight: .bold), color: tint, alignment: .right)

        let barRect = NSRect(x: rect.minX + 12, y: rect.minY + 33, width: rect.width - 24, height: 7)
        drawRoundedRect(barRect, fill: NSColor.separatorColor.withAlphaComponent(0.35), stroke: .clear, radius: 3.5)
        if let percent {
            let width = max(0, min(1, percent / 100)) * barRect.width
            drawRoundedRect(NSRect(x: barRect.minX, y: barRect.minY, width: width, height: barRect.height), fill: tint.withAlphaComponent(0.9), stroke: .clear, radius: 3.5)
        }
    }

    private func drawPill(_ text: String, at point: NSPoint, color: NSColor, fillColor: NSColor) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let width = ceil(NSString(string: text).size(withAttributes: [.font: font]).width) + 18
        let rect = NSRect(x: point.x, y: point.y, width: width, height: 24)
        drawRoundedRect(rect, fill: fillColor, stroke: .clear, radius: 8)
        drawText(text, in: rect.insetBy(dx: 9, dy: 4), font: font, color: color)
    }

    private func drawAccentLine(in rect: NSRect, color: NSColor) {
        color.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 12, y: rect.minY + 7, width: 18, height: 2), xRadius: 1, yRadius: 1).fill()
    }

    private func drawRoundedRect(_ rect: NSRect, fill: NSColor, stroke: NSColor, radius: CGFloat) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()
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

    private func formatRawNumber(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formatScaledNumber(_ value: Int64, maximumFractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        formatter.numberStyle = .decimal
        let doubleValue = Double(value)
        if value >= 100_000_000 {
            return "\(formatter.string(from: NSNumber(value: doubleValue / 100_000_000)) ?? String(format: "%.\(maximumFractionDigits)f", doubleValue / 100_000_000))亿"
        }
        if value >= 10_000 {
            return "\(formatter.string(from: NSNumber(value: doubleValue / 10_000)) ?? String(format: "%.\(maximumFractionDigits)f", doubleValue / 10_000))万"
        }
        return formatRawNumber(value)
    }

    private func formatPercent(_ percent: Double?) -> String {
        guard let percent else { return "--" }
        return String(format: "%.1f%%", percent)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let tokenStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let usageHeaderItem = NSMenuItem(title: "Usage", action: nil, keyEquivalent: "")
    private let fiveHourItem = NSMenuItem(title: "5 小时 --", action: nil, keyEquivalent: "")
    private let weeklyItem = NSMenuItem(title: "1 周 --", action: nil, keyEquivalent: "")
    private let resetCreditsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let resetCreditsView = ResetCreditsMenuView(frame: NSRect(x: 0, y: 0, width: 440, height: 86))
    private let localUsageHeaderItem = NSMenuItem(title: "Local Today", action: nil, keyEquivalent: "")
    private let localConsumptionItem = NSMenuItem(title: "消耗 --", action: nil, keyEquivalent: "")
    private let localCacheHitItem = NSMenuItem(title: "命中 --", action: nil, keyEquivalent: "")
    private let localUsageDetailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let localUsagePanelItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let localUsagePanelView = LocalUsageMenuView(frame: NSRect(x: 0, y: 0, width: 440, height: 224))
    private let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let autoLaunchItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let autoLaunchView = AutoLaunchMenuView(frame: NSRect(x: 0, y: 0, width: 440, height: 38))
    private var refreshTimer: Timer?
    private var isRefreshing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("Keep the Codex rate limits status item available")
        setupStatusItem()
        setupTokenStatusItem()
        setupMenu()
        configureAutoLaunch()
        refresh()
        refreshTimer = Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(timerRefresh), userInfo: nil, repeats: true)
    }

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.image = makeStatusImage(top: "5h --", bottom: "W --", style: .waiting)
        button.toolTip = "Codex rate limits"
        statusItem.menu = menu
    }

    private func setupTokenStatusItem() {
        guard let button = tokenStatusItem.button else { return }
        button.imagePosition = .imageOnly
        button.image = makeStatusImage(top: "消耗 --", bottom: "命中 --", style: .waiting)
        button.toolTip = "Codex local token usage"
        tokenStatusItem.menu = menu
    }

    private func setupMenu() {
        usageHeaderItem.isEnabled = false
        fiveHourItem.isEnabled = false
        weeklyItem.isEnabled = false
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
        resetCreditsItem.view = resetCreditsView
        localUsagePanelItem.view = localUsagePanelView
        errorItem.isHidden = true
        autoLaunchItem.view = autoLaunchView
        autoLaunchView.configure(target: self, action: #selector(toggleAutoLaunch))
        updateAutoLaunchMenu(enabled: AutoLaunchManager.preferredEnabled)

        menu.addItem(usageHeaderItem)
        menu.addItem(fiveHourItem)
        menu.addItem(weeklyItem)
        menu.addItem(resetCreditsItem)
        menu.addItem(.separator())
        menu.addItem(localUsagePanelItem)
        menu.addItem(localUsageHeaderItem)
        menu.addItem(localConsumptionItem)
        menu.addItem(localCacheHitItem)
        menu.addItem(localUsageDetailItem)
        menu.addItem(.separator())
        menu.addItem(errorItem)
        menu.addItem(autoLaunchItem)
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let openPluginItem = NSMenuItem(title: "Open Usage Plugin", action: #selector(openUsagePlugin), keyEquivalent: "")
        openPluginItem.target = self
        menu.addItem(openPluginItem)

        let openProjectItem = NSMenuItem(title: "Open Project Folder", action: #selector(openProjectFolder), keyEquivalent: "")
        openProjectItem.target = self
        menu.addItem(openProjectItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func refreshFromMenu() {
        refresh()
    }

    @objc private func timerRefresh() {
        refresh()
    }

    @objc private func toggleAutoLaunch() {
        setAutoLaunch(enabled: autoLaunchView.isChecked)
    }

    @objc private func openUsagePlugin() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Users/caohaidi/plugins/codex-usage-monitor"))
    }

    @objc private func openProjectFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Users/caohaidi/Projects/codex-rate_limits-bar"))
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
            if errorItem.title.hasPrefix("开机自启失败") {
                errorItem.title = ""
                errorItem.isHidden = true
            }
        } catch {
            updateAutoLaunchMenu(enabled: AutoLaunchManager.preferredEnabled)
            showAutoLaunchError(error)
        }
    }

    private func updateAutoLaunchMenu(enabled: Bool) {
        autoLaunchView.update(enabled: enabled)
    }

    private func showAutoLaunchError(_ error: Error) {
        errorItem.title = "开机自启失败：请查看提示"
        errorItem.toolTip = Self.errorToolTip(error)
        errorItem.isHidden = false
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.fetchRateLimits()
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

    private func apply(_ payload: RateLimitPayload) {
        let primary = payload.rateLimits?.primary
        let secondary = payload.rateLimits?.secondary
        let primaryRemaining = primary?.remainingPercent
        let secondaryRemaining = secondary?.remainingPercent
        let top = primaryRemaining.map { "5h \($0)%" } ?? "5h --"
        let bottom = secondaryRemaining.map { "W \($0)%" } ?? "W --"
        updateStatusImage(top: top, bottom: bottom, style: style(for: primaryRemaining, secondaryRemaining))

        fiveHourItem.title = formatUsageLine(label: "5 小时", remaining: primaryRemaining, window: primary, includeDate: false)
        weeklyItem.title = formatUsageLine(label: "1 周", remaining: secondaryRemaining, window: secondary, includeDate: true)
        errorItem.title = ""
        errorItem.toolTip = nil
        errorItem.isHidden = true
        let resetSuffix = payload.resetCredits?.availableCount.map { ", resets \($0)" } ?? ""
        statusItem.button?.toolTip = "Codex 5h \(primaryRemaining.map { "\($0)%" } ?? "--"), week \(secondaryRemaining.map { "\($0)%" } ?? "--")\(resetSuffix)"
        resetCreditsView.update(payload.resetCredits)

        if let localUsage = payload.localUsage {
            apply(localUsage)
        }
    }

    private func apply(_ localUsage: LocalUsageSnapshot) {
        let consumption = localUsage.display?.consumptionLabel ?? "消耗 \(formatTokenAmount(localUsage.totalTokens))"
        let cacheHit = "命中 \(formatPercent(localUsage.cacheHitPercent))"
        tokenStatusItem.button?.image = makeStatusImage(top: consumption, bottom: cacheHit, style: .normal)
        tokenStatusItem.button?.toolTip = "Codex 本机今日 \(formatTokenAmount(localUsage.totalTokens)), cache hit \(formatPercent(localUsage.cacheHitPercent))"

        localConsumptionItem.title = consumption
        localCacheHitItem.title = cacheHit
        localUsageDetailItem.title = "事件 \(localUsage.eventCount) · 文件 \(localUsage.filesWithEvents)/\(localUsage.filesScanned)"
        localUsageDetailItem.isHidden = true
        localUsagePanelView.update(localUsage)
    }

    private func apply(_ error: Error) {
        errorItem.title = Self.refreshErrorTitle(error)
        errorItem.toolTip = Self.errorToolTip(error)
        errorItem.isHidden = false
        statusItem.button?.toolTip = "Codex rate limit refresh failed; showing last value"
        tokenStatusItem.button?.toolTip = "Codex local usage refresh failed; showing last value"
    }

    private static func refreshErrorTitle(_ error: Error) -> String {
        let detail = normalizedErrorText(error)
        if detail.contains("account/rateLimits/read failed") {
            return "刷新失败：Codex 限额接口暂不可用"
        }
        if detail.contains("account/usage/read failed") {
            return "刷新失败：Codex 用量接口暂不可用"
        }
        if detail.contains("codex_rate_limits.js not found") {
            return "刷新失败：找不到 helper"
        }
        if detail.contains("node executable not found") {
            return "刷新失败：找不到 Node"
        }
        if detail.localizedCaseInsensitiveContains("timed out") || detail.localizedCaseInsensitiveContains("timeout") {
            return "刷新失败：Codex 接口超时"
        }
        return "刷新失败：Codex 状态暂不可用"
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

    private func updateStatusImage(top: String, bottom: String, style: StatusStyle) {
        statusItem.button?.image = makeStatusImage(top: top, bottom: bottom, style: style)
    }

    nonisolated private static func fetchRateLimits() -> Result<RateLimitPayload, Error> {
        do {
            let helper = try helperPath()
            let node = try nodePath()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = [helper, "status"]
            process.environment = mergedEnvironment()

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()

            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            if process.terminationStatus != 0 {
                let errorText = String(data: stderrData, encoding: .utf8) ?? "unknown error"
                throw RuntimeError(errorText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let decoder = JSONDecoder()
            return .success(try decoder.decode(RateLimitPayload.self, from: stdoutData))
        } catch {
            return .failure(error)
        }
    }

    nonisolated private static func helperPath() throws -> String {
        let candidates = [
            ProcessInfo.processInfo.environment["CODEX_RATE_LIMITS_HELPER"],
            Bundle.main.resourcePath.map { "\($0)/Scripts/codex_rate_limits.js" },
            "/Users/caohaidi/Projects/codex-rate_limits-bar/scripts/codex_rate_limits.js",
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if FileManager.default.isExecutableFile(atPath: candidate) || FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        throw RuntimeError("codex_rate_limits.js not found")
    }

    nonisolated private static func nodePath() throws -> String {
        let candidates = [
            ProcessInfo.processInfo.environment["CODEX_RATE_LIMITS_NODE"],
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        for candidate in candidates.compactMap({ $0 }) where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw RuntimeError("node executable not found")
    }

    nonisolated private static func mergedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = [extraPath, env["PATH"]].compactMap { $0 }.joined(separator: ":")
        return env
    }

    private func formatUsageLine(label: String, remaining: Int?, window: RateLimitWindow?, includeDate: Bool) -> String {
        let percentage = remaining.map { "\($0)%" } ?? "--"
        let reset = formatResetDisplay(window, includeDate: includeDate)
        guard !reset.isEmpty else { return "\(label) \(percentage)" }
        return "\(label) \(percentage) · \(reset)"
    }

    private func formatResetDisplay(_ window: RateLimitWindow?, includeDate: Bool) -> String {
        guard let window else { return "" }
        let date: Date?
        if let resetsAt = window.resetsAt {
            date = Date(timeIntervalSince1970: TimeInterval(resetsAt))
        } else {
            date = parseIsoDate(window.resetsAtIso)
        }
        guard let date else { return "" }

        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let display = DateFormatter()
        display.locale = Locale(identifier: "zh_Hans_CN")
        display.timeZone = TimeZone.current
        if includeDate || !calendar.isDateInToday(date) {
            display.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: Date()) ? "M月d日 HH:mm" : "yyyy年M月d日 HH:mm"
        } else {
            display.dateFormat = "HH:mm"
        }
        return display.string(from: date)
    }

    private func parseIsoDate(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: iso) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }

    private func style(for primary: Int?, _ secondary: Int?) -> StatusStyle {
        let lowest = min(primary ?? 100, secondary ?? 100)
        if lowest <= 10 { return .critical }
        if lowest <= 25 { return .warning }
        return .normal
    }

    private func formatTokenAmount(_ tokens: Int64) -> String {
        let value = Double(tokens)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.numberStyle = .decimal

        if tokens >= 100_000_000 {
            let formatted = formatter.string(from: NSNumber(value: value / 100_000_000)) ?? String(format: "%.2f", value / 100_000_000)
            return "\(formatted)亿"
        }
        if tokens >= 10_000 {
            let formatted = formatter.string(from: NSNumber(value: value / 10_000)) ?? String(format: "%.2f", value / 10_000)
            return "\(formatted)万"
        }
        return formatter.string(from: NSNumber(value: tokens)) ?? "\(tokens)"
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

    private func makeStatusImage(top: String, bottom: String, style: StatusStyle) -> NSImage {
        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.alignment = .right
        let valueParagraph = NSMutableParagraphStyle()
        valueParagraph.alignment = .left
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
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
        let topLine = splitStatusLine(top)
        let bottomLine = splitStatusLine(bottom)
        let titleWidth = ceil(max(
            NSString(string: topLine.title).size(withAttributes: titleAttributes).width,
            NSString(string: bottomLine.title).size(withAttributes: titleAttributes).width
        ))
        let valueWidth = ceil(max(
            NSString(string: topLine.value).size(withAttributes: valueAttributes).width,
            NSString(string: bottomLine.value).size(withAttributes: valueAttributes).width
        ))
        let gap: CGFloat = 7
        let horizontalPadding: CGFloat = 4
        let contentWidth = titleWidth + gap + valueWidth
        let size = NSSize(width: max(58, contentWidth + horizontalPadding * 2), height: 28)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let originX = floor((size.width - contentWidth) / 2)
        let titleRect = NSRect(x: originX, y: 0, width: titleWidth, height: 12)
        let valueRect = NSRect(x: originX + titleWidth + gap, y: 0, width: valueWidth, height: 12)
        NSString(string: topLine.title).draw(in: titleRect.offsetBy(dx: 0, dy: 14.5), withAttributes: titleAttributes)
        NSString(string: topLine.value).draw(in: valueRect.offsetBy(dx: 0, dy: 14.5), withAttributes: valueAttributes)
        NSString(string: bottomLine.title).draw(in: titleRect.offsetBy(dx: 0, dy: 2.5), withAttributes: titleAttributes)
        NSString(string: bottomLine.value).draw(in: valueRect.offsetBy(dx: 0, dy: 2.5), withAttributes: valueAttributes)
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
