import AppKit
import BlitterCore
import BlitterGit
import BlitterModel

/// The Git Clean window (#71): what `git clean` would remove, always shown first, with untracked
/// folders and ignored files as options; Move to Trash (the default), or Delete for Good after a
/// question (unless the settings turn questions off, as for Delete Immediately).
@MainActor
final class GitCleanWindowController: NSWindowController, NSWindowDelegate {
    let clean: GitClean
    let folderLabel = NSTextField(labelWithString: "")
    let foldersBox = NSButton(checkboxWithTitle: "Untracked folders too (-d)", target: nil, action: nil)
    let ignoredBox = NSButton(checkboxWithTitle: "Ignored files too (-x)", target: nil, action: nil)
    let listView = NSTextView()
    let statusLabel = NSTextField(labelWithString: "")
    let trashButton = NSButton(title: "Move to Trash", target: nil, action: nil)
    let deleteButton = NSButton(title: "Delete for Good…", target: nil, action: nil)
    /// Answers the question before deleting for good; tests answer it themselves.
    var confirmDelete: (Int, @escaping (Bool) -> Void) -> Void = { _, _ in }

    init(workspace: Workspace, path: String, access: GitCleanAccess = .real) {
        clean = GitClean(workspace: workspace, path: path, access: access)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Git Clean"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()
        confirmDelete = { [weak self] count, answer in self?.ask(count, answer) }
        clean.onChange = { [weak self] in self?.render() }
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func makeContent() -> NSView {
        folderLabel.lineBreakMode = .byTruncatingHead
        foldersBox.state = clean.includesFolders ? .on : .off
        ignoredBox.state = clean.includesIgnored ? .on : .off
        for box in [foldersBox, ignoredBox] {
            box.target = self
            box.action = #selector(optionsChanged(_:))
        }
        listView.isEditable = false
        listView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        listView.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = listView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        trashButton.target = self
        trashButton.action = #selector(moveToTrash(_:))
        trashButton.keyEquivalent = "\r"
        deleteButton.target = self
        deleteButton.action = #selector(deleteForGood(_:))
        deleteButton.hasDestructiveAction = true
        let buttons = NSStackView(views: [deleteButton, NSView(), trashButton])
        let options = NSStackView(views: [foldersBox, ignoredBox])
        options.spacing = 16
        let stack = NSStackView(views: [folderLabel, options, scroll, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [scroll, buttons, statusLabel, folderLabel] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        return stack
    }

    // MARK: Rendering

    func render() {
        folderLabel.stringValue = clean.folder.map { "In " + $0 } ?? "…"
        let folder = clean.folder.map { $0 + "/" } ?? ""
        let lines = (clean.items ?? []).map { $0.hasPrefix(folder) ? String($0.dropFirst(folder.count)) : $0 }
        let text = lines.joined(separator: "\n")
        if listView.string != text {
            listView.string = text
        }
        trashButton.isEnabled = clean.canRemove
        deleteButton.isEnabled = clean.canRemove
        deleteButton.title = clean.asksBeforeDeleting ? "Delete for Good…" : "Delete for Good"
        let (status, failed) = Self.statusLine(clean)
        statusLabel.stringValue = status
        statusLabel.textColor = failed ? .systemRed : .secondaryLabelColor
    }

    static func statusLine(_ clean: GitClean) -> (String, failed: Bool) {
        if let problem = clean.problem {
            return (problem, true)
        }
        if clean.runningJob != nil {
            return ("Removing…", false)
        }
        guard let items = clean.items else {
            return ("Asking git…", false)
        }
        var text = items.isEmpty ? "Nothing to clean."
            : items.count == 1 ? "1 item would go." : "\(items.count) items would go."
        if !clean.skippedRepositories.isEmpty {
            let count = clean.skippedRepositories.count
            text += count == 1 ? " 1 repository inside is left alone." : " \(count) repositories inside are left alone."
        }
        return (text, false)
    }

    // MARK: Input

    @objc private func optionsChanged(_: Any?) {
        clean.includesFolders = foldersBox.state == .on
        clean.includesIgnored = ignoredBox.state == .on
    }

    @objc private func moveToTrash(_: Any?) {
        clean.moveToTrash()
    }

    @objc private func deleteForGood(_: Any?) {
        let count = clean.items?.count ?? 0
        guard clean.asksBeforeDeleting else {
            clean.deleteForGood()
            return
        }
        confirmDelete(count) { [weak self] delete in
            if delete {
                self?.clean.deleteForGood()
            }
        }
    }

    /// The question before deleting for good: Cancel is the default button.
    private func ask(_ count: Int, _ answer: @escaping (Bool) -> Void) {
        guard let window else {
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 1 ? "Delete 1 item for good?" : "Delete \(count) items for good?"
        alert.informativeText = "They are deleted right away, not moved to the Trash. This cannot be undone."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            answer(response == .alertSecondButtonReturn)
        }
    }
}
