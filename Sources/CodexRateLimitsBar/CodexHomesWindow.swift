import AppKit
import CodexRateLimitsCore

@MainActor
final class CodexHomesWindow: NSWindowController {
    let selectionView: CodexHomesView

    init(selection: CodexHomeSelection, onApply: @escaping (CodexHomeSelection) throws -> Void) {
        selectionView = CodexHomesView(selection: selection)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = AppText.codexHomes
        window.minSize = NSSize(width: 600, height: 450)
        window.contentView = selectionView
        window.isReleasedWhenClosed = false
        super.init(window: window)
        selectionView.onApply = { [weak self] value in try onApply(value); self?.close() }
        selectionView.onCancel = { [weak self] in self?.close() }
        window.center()
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
final class CodexHomesView: NSView {
    var onApply: ((CodexHomeSelection) throws -> Void)?
    var onCancel: (() -> Void)?
    private let home: URL
    private var candidates: [CodexHomeCandidate] = []
    private var selectedPaths: Set<String>
    private var activePath: String
    private let accountLabel = NSTextField(labelWithString: AppText.officialAccountFolder)
    let accountPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scope = NSTextField(wrappingLabelWithString: AppText.codexHomeScope)
    private let foldersLabel = NSTextField(labelWithString: AppText.localUsageFolders)
    private let scroll = NSScrollView()
    private let rows = CodexHomeRowsView()
    private var checkboxes: [NSButton] = []
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let rescan = NSButton(title: AppText.rescanFolders, target: nil, action: nil)
    private let add = NSButton(title: AppText.addCodexFolder, target: nil, action: nil)
    private let apply = NSButton(title: AppText.applyCodexFolders, target: nil, action: nil)
    private let cancel = NSButton(title: AppText.cancelFolderSelection, target: nil, action: nil)

    init(selection: CodexHomeSelection, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        selectedPaths = Set(selection.localHomes)
        activePath = selection.activeHome
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 500))
        accountLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        foldersLabel.font = accountLabel.font
        scope.font = .systemFont(ofSize: 12)
        scope.textColor = .secondaryLabelColor
        errorLabel.textColor = .systemRed
        accountPopup.target = self
        accountPopup.action = #selector(accountChanged)
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = rows
        for view in [accountLabel, accountPopup, scope, foldersLabel, scroll, errorLabel, rescan, add, cancel, apply] {
            addSubview(view)
        }
        for (button, action) in [(rescan, #selector(rescanFolders)), (add, #selector(addFolder)),
                                 (cancel, #selector(cancelSelection)), (apply, #selector(applySelection))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        apply.keyEquivalent = "\r"
        cancel.keyEquivalent = "\u{1b}"
        reloadCandidates()
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    var selection: CodexHomeSelection {
        CodexHomeSelection(activeHome: URL(fileURLWithPath: activePath),
            localHomes: selectedPaths.map { URL(fileURLWithPath: $0) })
    }
    var candidateCount: Int { candidates.count }
    var checkedPaths: Set<String> { selectedPaths }

    func reloadCandidates() {
        candidates = CodexHomeDiscovery.discover(home: home, including: Array(selectedPaths) + [activePath])
        accountPopup.removeAllItems()
        for candidate in candidates {
            accountPopup.addItem(withTitle: candidate.displayPath(home: home))
            accountPopup.lastItem?.representedObject = candidate.path
            accountPopup.lastItem?.isEnabled = candidate.isAvailable
        }
        accountPopup.selectItem(at: candidates.firstIndex { $0.path == activePath } ?? 0)
        accountPopup.toolTip = activePath
        rows.subviews.forEach { $0.removeFromSuperview() }
        checkboxes = []
        for (index, candidate) in candidates.enumerated() {
            let check = NSButton(checkboxWithTitle: candidate.displayPath(home: home), target: self, action: #selector(localChanged(_:)))
            check.tag = index
            check.state = selectedPaths.contains(candidate.path) ? .on : .off
            check.isEnabled = candidate.path != activePath
            check.toolTip = candidate.path
            let detail = NSTextField(labelWithString: AppText.codexFolderEvidence(candidate))
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.tag = index
            rows.addSubview(check)
            rows.addSubview(detail)
            checkboxes.append(check)
        }
        errorLabel.stringValue = candidates.first { $0.path == activePath }?.isAvailable == true ? "" : AppText.folderUnavailable
        errorLabel.toolTip = nil
        scroll.contentView.scroll(to: .zero)
        needsLayout = true
    }

    @objc private func accountChanged() {
        guard let path = accountPopup.selectedItem?.representedObject as? String else { return }
        activePath = path
        selectedPaths.insert(path)
        reloadCandidates()
    }

    @objc private func localChanged(_ sender: NSButton) {
        let path = candidates[sender.tag].path
        if sender.state == .on { selectedPaths.insert(path) } else { selectedPaths.remove(path) }
    }

    @objc private func rescanFolders() { reloadCandidates() }
    @objc private func cancelSelection() { onCancel?() }
    @objc private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.directoryURL = home
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let candidate = CodexHomeDiscovery.candidate(url)
        guard candidate.isAvailable && (candidate.hasAuthentication || candidate.hasConfiguration || candidate.hasSessions) else {
            errorLabel.stringValue = AppText.folderSelectionError
            return
        }
        selectedPaths.insert(candidate.path)
        reloadCandidates()
    }

    @objc func applySelection() {
        let candidate = CodexHomeDiscovery.candidate(URL(fileURLWithPath: activePath))
        guard candidate.isAvailable else { errorLabel.stringValue = AppText.folderSelectionError; return }
        do { try onApply?(selection) }
        catch {
            errorLabel.stringValue = AppText.folderApplyError
            errorLabel.toolTip = error.localizedDescription
        }
    }

    override func layout() {
        super.layout()
        let width = bounds.width - 48
        accountLabel.frame = NSRect(x: 24, y: 24, width: width, height: 20)
        accountPopup.frame = NSRect(x: 22, y: 50, width: width + 4, height: 28)
        scope.frame = NSRect(x: 24, y: 88, width: width, height: 44)
        foldersLabel.frame = NSRect(x: 24, y: 144, width: width, height: 20)
        scroll.frame = NSRect(x: 24, y: 172, width: width, height: bounds.height - 276)
        rows.frame = NSRect(x: 0, y: 0, width: width - 20, height: max(scroll.contentSize.height, CGFloat(candidates.count) * 56 + 8))
        for (index, check) in checkboxes.enumerated() {
            let y = CGFloat(index) * 56 + 8
            check.frame = NSRect(x: 12, y: y, width: rows.bounds.width - 24, height: 24)
            if let detail = rows.subviews.compactMap({ $0 as? NSTextField }).first(where: { $0.tag == index }) {
                detail.frame = NSRect(x: 32, y: y + 27, width: rows.bounds.width - 44, height: 17)
            }
        }
        errorLabel.frame = NSRect(x: 24, y: bounds.height - 95, width: width, height: 25)
        rescan.frame = NSRect(x: 24, y: bounds.height - 54, width: 100, height: 30)
        add.frame = NSRect(x: 130, y: bounds.height - 54, width: 126, height: 30)
        cancel.frame = NSRect(x: bounds.width - 264, y: bounds.height - 54, width: 90, height: 30)
        apply.frame = NSRect(x: bounds.width - 172, y: bounds.height - 54, width: 148, height: 30)
    }
}

@MainActor
private final class CodexHomeRowsView: NSView {
    override var isFlipped: Bool { true }
}
