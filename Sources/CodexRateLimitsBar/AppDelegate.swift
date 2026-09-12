import AppKit
import CodexRateLimitsCore
import Foundation

import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let tokenStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let notificationCenter = UNUserNotificationCenter.current()
    private let refreshController = UsageRefreshController()
    private lazy var refreshEvents = RefreshEventMonitor(controller: refreshController)
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
    private var currentAutoLaunchError: String?
    private var currentNotificationError: String?
    private var lastLoggedErrorDetails: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("Keep the Codex rate limits status item available")
        setupStatusItem()
        setupTokenStatusItem()
        setupMenu()
        refreshController.onChange = { [weak self] in self?.renderRefreshState() }
        refreshController.onQuotaAlert = { [weak self] request, completion in
            self?.deliverQuotaAlert(request, completion: completion)
        }
        refreshController.onCancelQuotaAlerts = { [weak self] in
            self?.notificationCenter.removePendingNotificationRequests(withIdentifiers: $0)
        }
        configureAutoLaunch()
        configureLocalUsageStatusItemVisibility()
        configureQuotaAlerts()
        refreshController.refresh()
        refreshEvents.start()
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

    @objc private func refreshFromMenu() { refreshController.refresh() }

    @objc private func rebuildLocalUsage() { refreshController.refreshLocal(reason: .rebuild) }

    func menuWillOpen(_ menu: NSMenu) { refreshController.heartbeat() }

    func applicationWillTerminate(_ notification: Notification) {
        refreshEvents.stop()
        refreshController.stop()
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
        refreshController.alertsEnabled = enabled
        currentNotificationError = error
        preferencesView.updateQuotaAlerts(enabled: enabled)
        updateCombinedError()
        if enabled {
            refreshController.refreshOfficial()
        }
    }

    private func showAutoLaunchError(_ error: Error) {
        currentAutoLaunchError = Self.errorToolTip(error)
        updateCombinedError()
    }

    private func deliverQuotaAlert(_ delivery: QuotaAlertRequest,
                                   completion: @escaping @MainActor @Sendable (String?) -> Void) {
        let event = delivery.event
        let content = UNMutableNotificationContent()
        content.title = AppText.quotaAlertTitle(event)
        content.body = AppText.quotaAlertBody(event)
        content.sound = .default
        content.threadIdentifier = "quota-alerts"
        let request = UNNotificationRequest(identifier: delivery.identifier, content: content, trigger: nil)
        notificationCenter.add(request) { error in
            Task { @MainActor in
                completion(error.map(Self.normalizedErrorText))
            }
        }
    }

    private func renderRefreshState() {
        let state = refreshController.state
        let freshness = refreshController.freshness
        let quotaOld = freshness.quota.isStale || freshness.quota.error != nil
        let localOld = freshness.localUsage.isStale || freshness.localUsage.error != nil
        accountItem.title = AppText.accountSource(state.accountContext)
        accountItem.toolTip = AppText.accountSourceDetail(state.accountContext)
        updateStatusImage(state.weeklyRemaining.map { "W \($0)%" } ?? "W --", reset: state.weeklyWindow?.resetDate.map(AppText.statusBarResetDate))
        statusItem.button?.alphaValue = quotaOld ? 0.55 : 1
        tokenStatusItem.button?.alphaValue = localOld ? 0.55 : 1
        let forecast = quotaOld ? nil : state.quotaForecast
        let cost = quotaOld || localOld ? nil : state.matchingWeeklyQuotaCost
        rateLimitsView.update(weekly: state.weeklyWindow, forecast: forecast, weeklyQuotaCost: cost, credits: state.credits, freshness: freshness)
        resetCreditsView.update(state.resetCredits, freshness: freshness.resetCredits)
        localUsagePanelView.update(state.localUsage, freshness: freshness.localUsage)
        statusItem.button?.toolTip = AppText.rateLimitTooltip(
            weekly: state.weeklyRemaining.map { "\($0)%" } ?? "--", resetCount: state.resetAvailableCount,
            forecast: forecast, weeklyQuotaCost: cost) + "\n" + AppText.officialCreditsBalance(state.credits)
            + "\n" + AppText.refreshDetails(freshness)
        let consumption = state.localUsage?.display?.consumptionLabel ?? AppText.consumption(nil)
        let cacheHit = AppText.cacheHit(formatPercent(state.localUsage?.cacheHitPercent))
        tokenStatusItem.button?.image = makeStatusImage(top: consumption, bottom: cacheHit)
        tokenStatusItem.button?.toolTip = [state.localUsage?.display?.estimatedCostLabel,
            state.localUsage?.display?.estimatedCreditsLabel, state.localUsage?.display?.pricingCoverageLabel,
            AppText.unpricedUsageDetails(state.localUsage?.unpricedUsage), AppText.pricingDetails(state.localUsage?.pricing),
            state.localUsage.map(AppText.scanDetails), AppText.refreshDetails(freshness)].compactMap { $0 }.joined(separator: "\n")
        updateCombinedError()
    }

    private func updateCombinedError() {
        let state = refreshController.state
        let freshness = refreshController.freshness
        var details = RefreshSource.allCases.compactMap { source in
            freshness[source].error.map { "\(AppText.refreshSourceName(source)): \($0)" }
        }
        if let error = currentAutoLaunchError { details.append("\(AppText.autoLaunchFailure): \(error)") }
        if let persistence = state.localUsage?.persistence, persistence.status == .pending {
            details.append([AppText.cachePersistence(persistence), persistence.error].compactMap { $0 }.joined(separator: ": "))
        }
        if let quotaMonitorError = state.quotaMonitorError, !quotaMonitorError.isEmpty {
            details.append("\(AppText.quotaForecastErrorLabel): \(quotaMonitorError)")
        }
        if let notificationError = currentNotificationError ?? state.quotaAlertError, !notificationError.isEmpty {
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
