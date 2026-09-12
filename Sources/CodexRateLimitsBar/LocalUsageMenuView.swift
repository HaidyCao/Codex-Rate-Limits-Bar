import AppKit
import CodexRateLimitsCore
import Foundation

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
        toolTip = [snapshot?.display?.estimatedCreditsLabel ?? AppText.todayEstimatedCredits(snapshot?.todayCredits),
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
        let newInputTokens = max(0, max(0, inputTokens - cachedInputTokens) - cacheWriteInputTokens)
        let outputTokens = snapshot?.outputTokens ?? 0
        let eventCount = snapshot?.eventCount ?? 0
        let cacheHitPercent = snapshot?.cacheHitPercent

        drawSymbol("cpu.fill", in: NSRect(x: 12, y: 12, width: 14, height: 14), color: secondaryColor)
        drawText(AppText.localUsageTitle, in: NSRect(x: 32, y: 10, width: 250, height: 18), font: .systemFont(ofSize: 12, weight: .bold), color: labelColor)

        let unavailable = snapshot == nil || snapshot?.diagnostics?.status == .unavailable
        let breakdownUnavailable = unavailable || snapshot?.hasIncompleteTokenBreakdown == true
        let rawTotal = unavailable ? "--" : formatRawNumber(totalTokens)
        let rawFont = NSFont.monospacedDigitSystemFont(ofSize: 32, weight: .bold)
        let rawWidth = ceil(NSString(string: rawTotal).size(withAttributes: [.font: rawFont]).width)
        drawText(rawTotal, in: NSRect(x: 12, y: 32, width: min(rawWidth + 4, bounds.width - 176), height: 42), font: rawFont, color: labelColor)

        let requestRect = NSRect(x: bounds.width - 152, y: 12, width: 140, height: 58)
        drawSubCard(requestRect, fill: subCardFill, stroke: subCardStroke)
        drawText(AppText.todayEstimatedCostCardTitle(requests: eventCount), in: NSRect(x: requestRect.minX + 10, y: requestRect.minY + 6, width: requestRect.width - 20, height: 16), font: .systemFont(ofSize: 10.5, weight: .semibold), color: secondaryColor)
        let amount = unavailable ? nil : snapshot?.todayCost?.estimatedCostUSD
        let cost = USDFormatter.string(amount)
        let costSuffix = amount == nil ? "" : snapshot?.diagnostics?.status == .partial ? "*" : snapshot?.todayCost?.isPartial == true ? "+" : ""
        drawText("\(cost)\(costSuffix)", in: NSRect(x: requestRect.minX + 10, y: requestRect.minY + 24, width: requestRect.width - 20, height: 24), font: .monospacedDigitSystemFont(ofSize: 18, weight: .bold), color: labelColor)

        let padding: CGFloat = 12
        let gap: CGFloat = 8
        let gridWidth = bounds.width - padding * 2
        let cardWidth = floor((gridWidth - gap) / 2)
        let cardHeight: CGFloat = 52

        let rowOneY: CGFloat = 84
        let rowTwoY: CGFloat = 144

        let rect1 = NSRect(x: padding, y: rowOneY, width: cardWidth, height: cardHeight)
        drawMetricCard(rect1, title: AppText.newInput, value: breakdownUnavailable ? "--" : TokenAmountFormatter.compact(newInputTokens, maximumFractionDigits: 1), tint: blue, fill: subCardFill, stroke: subCardStroke)

        let rect2 = NSRect(x: padding + cardWidth + gap, y: rowOneY, width: cardWidth, height: cardHeight)
        drawMetricCard(rect2, title: AppText.output, value: breakdownUnavailable ? "--" : TokenAmountFormatter.compact(outputTokens, maximumFractionDigits: 1), tint: purple, fill: subCardFill, stroke: subCardStroke)

        let rect3 = NSRect(x: padding, y: rowTwoY, width: cardWidth, height: cardHeight)
        drawMetricCard(rect3, title: AppText.hit, value: breakdownUnavailable ? "--" : TokenAmountFormatter.compact(cachedInputTokens, maximumFractionDigits: 2), tint: green, fill: subCardFill, stroke: subCardStroke)

        let rect4 = NSRect(x: padding + cardWidth + gap, y: rowTwoY, width: cardWidth, height: cardHeight)
        drawCacheHitCard(rect4, percent: breakdownUnavailable ? nil : cacheHitPercent, fill: subCardFill, stroke: subCardStroke, tint: green)

        drawText(AppText.todayEstimatedCredits(unavailable ? nil : snapshot?.todayCredits), in: NSRect(x: 12, y: 210, width: bounds.width - 24, height: 20), font: .monospacedDigitSystemFont(ofSize: 13, weight: .semibold), color: labelColor)
        drawText(AppText.pricingCoverage(cost: snapshot?.todayCost, credits: snapshot?.todayCredits), in: NSRect(x: 12, y: 234, width: bounds.width - 24, height: 16), font: .systemFont(ofSize: 10.5), color: secondaryColor)
        drawText(AppText.scanStatus(snapshot?.diagnostics), in: NSRect(x: 12, y: 254, width: bounds.width - 24, height: 16), font: .systemFont(ofSize: 10.5, weight: .medium), color: snapshot?.diagnostics?.status.isIncomplete == true ? .systemOrange : secondaryColor)
        drawText(AppText.billingAssumptions(snapshot?.billingAssumptions) ?? "", in: NSRect(x: 12, y: 276, width: bounds.width - 24, height: 16), font: .systemFont(ofSize: 10.5), color: secondaryColor)
        let unpricedSummary = snapshot?.hasIncompleteTokenBreakdown == true ? AppText.incompleteTokenBreakdown
            : AppText.unpricedModels(cost: snapshot?.todayCost, credits: snapshot?.todayCredits) ?? ""
        drawText(unpricedSummary, in: NSRect(x: 12, y: 298, width: bounds.width - 24, height: 16), font: .systemFont(ofSize: 10.5), color: secondaryColor)
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
