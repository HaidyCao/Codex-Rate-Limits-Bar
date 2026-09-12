import AppKit
import CodexRateLimitsCore
import Foundation

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
