import AppKit
import BlitterModel

/// The Find panel (#48), docked below both sides: a name to search for below the active side's
/// folder, and how the search is going. The results show on that side, as a folder of their own.
/// ⌘F shows it and puts the cursor in the field; Escape (or ✕) hides it again, the results stay.
@MainActor
final class FindPanelController: NSViewController, NSSearchFieldDelegate {
    private let workspace: Workspace
    let field = NSSearchField()
    let scopeLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    /// Called when the panel shows or hides, so the window can make room.
    var onVisibilityChange: (() -> Void)?

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        field.placeholderString = "Name, or a pattern such as *.swift"
        field.sendsWholeSearchString = true
        field.target = self
        field.action = #selector(search(_:))
        field.delegate = self
        stopButton.target = self
        stopButton.action = #selector(stop(_:))
        let close = NSButton(title: "✕", target: self, action: #selector(close(_:)))
        close.isBordered = false
        close.toolTip = "Hide the Find panel (Escape); the results stay"
        for label in [scopeLabel, statusLabel] {
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let row = NSStackView(views: [NSTextField(labelWithString: "Find:"), field, scopeLabel, NSView(), statusLabel,
                                      stopButton, close])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        view = row
        view.isHidden = true
    }

    /// Shows the panel and puts the cursor in its field.
    func show() {
        if view.isHidden {
            view.isHidden = false
            onVisibilityChange?()
        }
        render()
        view.window?.makeFirstResponder(field)
    }

    func hide() {
        guard !view.isHidden else {
            return
        }
        view.isHidden = true
        onVisibilityChange?()
    }

    func render() {
        guard isViewLoaded, !view.isHidden else {
            return
        }
        let state = workspace.state(of: workspace.activeSide)
        scopeLabel.stringValue = "in " + (state.find?.root ?? state.location)
        stopButton.isEnabled = state.find?.isRunning == true
        statusLabel.stringValue = state.find.map { Self.status($0, found: state.visibleEntries.count) } ?? ""
    }

    static func status(_ find: FindState, found: Int) -> String {
        let folders = find.foldersSearched == 1 ? "1 folder" : "\(find.foldersSearched.formatted()) folders"
        var text = (find.isRunning ? "Searching… " : "") + "\(found.formatted()) found in \(folders)"
        if find.unreadableFolders > 0 {
            text += " (\(find.unreadableFolders.formatted()) could not be read)"
        }
        return text
    }

    // MARK: Input

    @objc private func search(_: Any?) {
        workspace.perform(.find(workspace.activeSide, pattern: field.stringValue))
    }

    @objc private func stop(_: Any?) {
        workspace.perform(.stopFind(workspace.activeSide))
    }

    @objc private func close(_: Any?) {
        hide()
    }

    /// Escape hides the panel (and gives the keys back to the list).
    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else {
            return false
        }
        hide()
        return true
    }
}
