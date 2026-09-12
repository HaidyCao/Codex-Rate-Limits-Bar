import AppKit
import CodexRateLimitsCore
import Network

/// Adapts system events to the Core controller. Scheduling policy lives in Core.
@MainActor
final class RefreshEventMonitor: NSObject {
    private weak var controller: UsageRefreshController?
    private var timer: Timer?
    private let network = NWPathMonitor()

    init(controller: UsageRefreshController) { self.controller = controller }

    func start() {
        let timer = Timer(timeInterval: 5, target: self, selector: #selector(heartbeat), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        network.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in self?.controller?.setNetworkAvailable(available) }
        }
        network.start(queue: DispatchQueue(label: "local.codex.network"))
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        network.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func heartbeat() { controller?.heartbeat() }
    @objc private func willSleep() { controller?.sleep() }
    @objc private func didWake() { controller?.wake() }
}
