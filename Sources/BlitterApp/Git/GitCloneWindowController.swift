import AppKit
import BlitterCore
import BlitterGit
import BlitterModel

/// The Git Clone window (#70): the repository's address, the new folder's name (taken from the
/// address until it is typed), and git's output while it clones. It closes once the clone is
/// done; a failure stays shown.
@MainActor
final class GitCloneWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    let clone: GitClone
    let addressField = NSTextField()
    let nameField = NSTextField()
    let statusLabel = NSTextField(labelWithString: "")
    let outputView = NSTextView()
    let cloneButton = NSButton(title: "Clone", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let outputScroll = NSScrollView()
    /// The name was typed: the address no longer changes it.
    private var nameTyped = false

    init(workspace: Workspace, folder: String, findGit: @escaping @Sendable () -> String? = { Git.executable }) {
        clone = GitClone(workspace: workspace, folder: folder, findGit: findGit)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Git Clone"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent(folder: folder)
        window.center()
        clone.onChange = { [weak self] in self?.render() }
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func makeContent(folder: String) -> NSView {
        addressField.placeholderString = "https://github.com/me/project.git or git@github.com:me/project.git"
        nameField.placeholderString = "Folder name"
        for field in [addressField, nameField] {
            field.delegate = self
        }
        let into = NSTextField(labelWithString: folder)
        into.lineBreakMode = .byTruncatingHead
        let form = NSGridView(views: [
            [NSTextField(labelWithString: "Repository:"), addressField],
            [NSTextField(labelWithString: "Folder name:"), nameField],
            [NSTextField(labelWithString: "Into:"), into],
        ])
        form.column(at: 0).xPlacement = .trailing
        form.rowSpacing = 8
        addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true

        outputView.isEditable = false
        outputView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        outputView.autoresizingMask = [.width]
        outputScroll.documentView = outputView
        outputScroll.hasVerticalScroller = true
        outputScroll.borderType = .bezelBorder
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3

        cloneButton.target = self
        cloneButton.action = #selector(startClone(_:))
        cloneButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancelButton, cloneButton])

        let stack = NSStackView(views: [form, outputScroll, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [outputScroll, buttons, statusLabel] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        outputScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        return stack
    }

    // MARK: Rendering

    func render() {
        let cloning = clone.state == .cloning
        addressField.isEnabled = !cloning
        nameField.isEnabled = !cloning
        let problem = clone.problem(address: addressField.stringValue, name: nameField.stringValue)
        cloneButton.isEnabled = clone.isReady && !cloning && problem == nil && clone.state != .succeeded
        cancelButton.title = cloning ? "Stop" : "Cancel"
        if outputView.string != clone.output {
            outputView.string = clone.output
            outputView.scrollToEndOfDocument(nil)
        }
        let (text, failed) = Self.statusLine(clone.state, problem: problem, typed: !addressField.stringValue.isEmpty)
        statusLabel.stringValue = text
        statusLabel.textColor = failed ? .systemRed : .secondaryLabelColor
        if clone.state == .succeeded {
            close() // the new folder is selected in the list
        }
    }

    static func statusLine(_ state: GitClone.State, problem: String?, typed: Bool) -> (String, failed: Bool) {
        switch state {
        case .cloning: ("Cloning…", false)
        case .succeeded: ("Cloned.", false)
        case let .failed(message): ("Git Clone failed: " + message, true)
        case .cancelled: ("Stopped.", false)
        case .editing: (typed ? problem ?? "" : "", problem != nil && typed)
        }
    }

    // MARK: Input

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === nameField {
            nameTyped = !nameField.stringValue.isEmpty
        } else if !nameTyped {
            nameField.stringValue = GitClone.name(from: addressField.stringValue)
        }
        render()
    }

    @objc private func startClone(_: Any?) {
        clone.clone(address: addressField.stringValue, name: nameField.stringValue)
    }

    @objc private func cancel(_: Any?) {
        if clone.state == .cloning {
            clone.cancel()
        } else {
            close()
        }
    }
}
