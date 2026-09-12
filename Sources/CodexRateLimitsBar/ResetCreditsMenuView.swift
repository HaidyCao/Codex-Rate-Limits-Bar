import AppKit
import CodexRateLimitsCore
import Foundation

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
