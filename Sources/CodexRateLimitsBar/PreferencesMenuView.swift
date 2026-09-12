import AppKit
import CodexRateLimitsCore
import Foundation

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
