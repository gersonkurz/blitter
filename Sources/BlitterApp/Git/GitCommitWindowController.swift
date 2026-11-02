import AppKit
import BlitterCore
import BlitterGit
import BlitterModel

/// The Git Commit window (#44): the changed and untracked files with checkboxes, the message
/// (or an earlier one), and Commit or Commit & Push. A double-click (or Return) on a file shows
/// it in the diff tool; Space checks or unchecks the selected files.
@MainActor
final class GitCommitWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
    NSTextViewDelegate
{
    let committer: GitCommitter
    let branchLabel = NSTextField(labelWithString: "")
    let filesTable = ActivatingTableView()
    let messageView = NSTextView()
    let recentMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    let commitButton = NSButton(title: "Commit", target: nil, action: nil)
    let commitPushButton = NSButton(title: "Commit & Push", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let statusLabel = NSTextField(labelWithString: "")
    let outputView = NSTextView()
    private(set) var renderedFiles: [GitFileChange] = []
    fileprivate var renderedChecks: Set<String> = []
    private var renderedMessages: [String] = []
    private var renderedOutcome: GitCommitter.Outcome?
    /// The message of the last commit started here.
    private var submitted: String?

    init(workspace: Workspace, path: String, access: GitCommitAccess = .real) {
        committer = GitCommitter(workspace: workspace, path: path, access: access)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
                              defer: false)
        window.title = "Git Commit — " + ((committer.root ?? path) as NSString).lastPathComponent
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = makeContent()
        window.center()
        committer.onChange = { [weak self] in self?.render() }
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Layout

    private func makeContent() -> NSView {
        configureTable()

        let allButton = NSButton(title: "Check All", target: self, action: #selector(checkAll(_:)))
        let noneButton = NSButton(title: "Uncheck All", target: self, action: #selector(uncheckAll(_:)))
        let top = NSStackView(views: [branchLabel, NSView(), allButton, noneButton])

        messageView.isRichText = false
        messageView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        messageView.isAutomaticQuoteSubstitutionEnabled = false
        messageView.isAutomaticDashSubstitutionEnabled = false
        messageView.delegate = self
        recentMenu.addItem(withTitle: "Recent Messages")
        recentMenu.lastItem?.tag = -1
        recentMenu.target = self
        recentMenu.action = #selector(recentChosen(_:))
        let messageRow = NSStackView(views: [NSTextField(labelWithString: "Message:"), NSView(), recentMenu])

        commitButton.target = self
        commitButton.action = #selector(commit(_:))
        commitButton.keyEquivalent = "\r"
        commitButton.keyEquivalentModifierMask = .command
        commitPushButton.target = self
        commitPushButton.action = #selector(commitAndPush(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancelRunning(_:))
        let buttons = NSStackView(views: [statusLabel, NSView(), cancelButton, commitPushButton, commitButton])
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        outputView.isEditable = false
        outputView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

        let files = Self.scrolling(filesTable, minHeight: 160)
        let message = Self.scrolling(messageView, minHeight: 72)
        let output = Self.scrolling(outputView, minHeight: 60)
        let stack = NSStackView(views: [top, files, messageRow, message, buttons, output])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for view in [top, files, messageRow, message, buttons, output] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        files.setContentHuggingPriority(.defaultLow - 1, for: .vertical) // the files take the room
        return stack
    }

    private func configureTable() {
        for (id, title, width) in [("check", "", 24.0), ("status", "", 30.0), ("path", "File", 640.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            filesTable.addTableColumn(column)
        }
        filesTable.style = .fullWidth
        filesTable.rowSizeStyle = .small
        filesTable.usesAlternatingRowBackgroundColors = true
        filesTable.allowsMultipleSelection = true
        filesTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        filesTable.dataSource = self
        filesTable.delegate = self
        filesTable.target = self
        filesTable.doubleAction = #selector(compareClicked(_:))
        filesTable.onReturn = { [weak self] in self?.compare(row: self?.filesTable.selectedRow ?? -1) }
        filesTable.onSpace = { [weak self] in self?.toggleSelected() }
    }

    private static func scrolling(_ view: NSView, minHeight: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        if let text = view as? NSTextView { // grows downwards with its text, wraps at the width
            text.minSize = .zero
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.textContainerInset = NSSize(width: 4, height: 4)
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true
        return scroll
    }

    // MARK: Rendering

    func render() {
        let changes = committer.changes
        branchLabel.stringValue = changes.map { changes in
            (changes.branch ?? "(detached HEAD)") + (changes.upstream.map { " → " + $0 } ?? " (no upstream)")
        } ?? "…"
        let files = changes?.files ?? []
        if files != renderedFiles {
            renderedFiles = files
            renderedChecks = committer.checked
            filesTable.reloadData()
        } else if committer.checked != renderedChecks {
            renderedChecks = committer.checked // only the checkboxes: the selection stays as it is
            filesTable.reloadData(forRowIndexes: IndexSet(integersIn: 0 ..< files.count), columnIndexes: [0])
        }
        if committer.recentMessages != renderedMessages {
            renderedMessages = committer.recentMessages
            while recentMenu.numberOfItems > 1 { // the first item is the title
                recentMenu.removeItem(at: 1)
            }
            // Items of their own, not `addItems(withTitles:)`, which merges equal titles.
            for (index, message) in renderedMessages.enumerated() {
                let item = NSMenuItem(title: String(message.prefix { $0 != "\n" }), action: nil, keyEquivalent: "")
                item.tag = index
                recentMenu.menu?.addItem(item)
            }
        }
        recentMenu.isEnabled = !renderedMessages.isEmpty && committer.running == nil
        messageView.isEditable = committer.running == nil // the message is the one being committed
        if committer.outcome != renderedOutcome {
            renderedOutcome = committer.outcome
            if case .committed = renderedOutcome, messageView.string == submitted {
                messageView.string = "" // done with it; one written meanwhile stays
            }
        }
        if outputView.string != committer.output {
            outputView.string = committer.output
            outputView.scrollToEndOfDocument(nil)
        }
        renderButtons()
        let (text, failed) = statusLine()
        statusLabel.stringValue = text
        statusLabel.textColor = failed ? .systemRed : .secondaryLabelColor
    }

    private func renderButtons() {
        let canCommit = committer.canCommit(message: messageView.string)
        commitButton.isEnabled = canCommit
        commitPushButton.isEnabled = canCommit && committer.changes?.upstream != nil
        cancelButton.isEnabled = committer.running != nil
    }

    func statusLine() -> (String, failed: Bool) {
        if let problem = committer.problem {
            return (problem, true)
        }
        if let running = committer.running {
            return ("\(running.title)…", false)
        }
        switch committer.outcome {
        case let .committed(pushed): return (pushed ? "Committed and pushed." : "Committed.", false)
        case let .failed(step, message): return ("\(step.title) failed: \(message)", true)
        case let .cancelled(step): return ("\(step.title) cancelled.", false)
        case nil: break
        }
        guard let changes = committer.changes else {
            return ("Reading the changes…", false)
        }
        return changes.files.isEmpty ? ("Nothing to commit.", false)
            : ("\(committer.checked.count) of \(changes.files.count) files checked", false)
    }

    // MARK: Input

    func textDidChange(_: Notification) {
        renderButtons()
    }

    @objc private func checkAll(_: Any?) {
        committer.perform(.checkAll(true))
    }

    @objc private func uncheckAll(_: Any?) {
        committer.perform(.checkAll(false))
    }

    @objc private func checkboxClicked(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < renderedFiles.count else {
            return
        }
        committer.perform(.check([renderedFiles[sender.tag].path], sender.state == .on))
    }

    /// Space: checks the selected files, or unchecks them if all of them are checked.
    private func toggleSelected() {
        let paths = filesTable.selectedRowIndexes.filter { $0 < renderedFiles.count }.map { renderedFiles[$0].path }
        let allChecked = paths.allSatisfy(committer.checked.contains)
        committer.perform(.check(paths, !allChecked))
    }

    @objc private func recentChosen(_: Any?) {
        guard let index = recentMenu.selectedItem?.tag, index >= 0, index < renderedMessages.count else {
            return
        }
        messageView.string = renderedMessages[index]
        renderButtons()
    }

    @objc private func commit(_: Any?) {
        submit(push: false)
    }

    @objc private func commitAndPush(_: Any?) {
        submit(push: true)
    }

    private func submit(push: Bool) {
        submitted = messageView.string
        committer.perform(.commit(message: messageView.string, push: push))
    }

    @objc private func cancelRunning(_: Any?) {
        committer.perform(.cancel)
    }

    @objc private func compareClicked(_: Any?) {
        compare(row: filesTable.clickedRow)
    }

    private func compare(row: Int) {
        guard row >= 0, row < renderedFiles.count else {
            return
        }
        committer.perform(.compare(renderedFiles[row].path))
    }
}

// MARK: Data source

extension GitCommitWindowController {
    func numberOfRows(in _: NSTableView) -> Int {
        renderedFiles.count
    }

    func tableView(_ table: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column, row < renderedFiles.count else {
            return nil
        }
        let file = renderedFiles[row]
        if column.identifier.rawValue == "check" {
            let box = table.makeView(withIdentifier: column.identifier, owner: nil) as? NSButton
                ?? makeCheckbox(column.identifier)
            box.tag = row
            box.state = renderedChecks.contains(file.path) ? .on : .off
            return box
        }
        let cell = table.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView
            ?? Self.makeCell(column.identifier)
        cell.textField?.stringValue = column.identifier.rawValue == "status" ? Self.letters(file)
            : file.oldPath.map { "\($0) → \(file.path)" } ?? file.path
        return cell
    }

    /// As `git status --short` shows them: the index's letter, then the working tree's.
    static func letters(_ file: GitFileChange) -> String {
        // "??" only for a file with nothing staged: `git rm --cached` shows as "D?" (#44 review).
        file.isUntracked && file.staged == nil ? "??" : String(file.staged ?? " ") + String(file.unstaged ?? " ")
    }

    private func makeCheckbox(_ identifier: NSUserInterfaceItemIdentifier) -> NSButton {
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxClicked(_:)))
        box.identifier = identifier
        return box
    }

    private static func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = identifier.rawValue == "status" ? MonospacedTextField(labelWithString: "")
            : NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
