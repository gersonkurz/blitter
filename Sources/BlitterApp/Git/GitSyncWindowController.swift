import AppKit
import BlitterCore
import BlitterGit
import BlitterModel

/// The Git Sync window (#43): where the branch stands, Fetch, Pull (rebase), Fetch & Rebase (#45)
/// and Push, and the running operation's output. The operations are jobs: the jobs strip shows
/// them too. While a rebase is stopped, a row offers to abort it or open the terminal.
@MainActor
final class GitSyncWindowController: NSWindowController, NSWindowDelegate {
    let sync: GitSync
    let branchLabel = NSTextField(labelWithString: "")
    let upstreamLabel = NSTextField(labelWithString: "")
    let stateLabel = NSTextField(labelWithString: "")
    let fetchedLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let outputView = NSTextView()
    private(set) var operationButtons: [GitSync.Operation: NSButton] = [:]
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let terminalButton = NSButton(title: "Open in Terminal", target: nil, action: nil)
    /// Abort Rebase and Open in Terminal, shown while a rebase is under way.
    let rebaseRow = NSStackView()
    private let dateFormatter: DateFormatter

    init(workspace: Workspace, path: String, access: GitSyncAccess = .real) {
        sync = GitSync(workspace: workspace, path: path, access: access)
        dateFormatter = Formatting.dateFormatter(workspace.settings.dateFormat)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
                              defer: false)
        window.title = "Git Sync — " + ((sync.root ?? path) as NSString).lastPathComponent
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()
        sync.onChange = { [weak self] in self?.render() }
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Layout

    private func makeContent() -> NSView {
        let facts = NSGridView(views: [
            [NSTextField(labelWithString: "Branch:"), branchLabel],
            [NSTextField(labelWithString: "Upstream:"), upstreamLabel],
            [NSTextField(labelWithString: "State:"), stateLabel],
            [NSTextField(labelWithString: "Last fetch:"), fetchedLabel],
        ])
        facts.column(at: 0).xPlacement = .trailing
        facts.rowSpacing = 4

        for operation in GitSync.Operation.allCases {
            let button = NSButton(title: operation.title, target: self, action: #selector(runOperation(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(operation.rawValue)
            operationButtons[operation] = button
        }
        cancelButton.target = self
        cancelButton.action = #selector(cancelRunning(_:))
        let row = NSStackView(views: GitSync.Operation.syncing.compactMap { operationButtons[$0] } + [cancelButton])
        row.spacing = 8
        terminalButton.target = self
        terminalButton.action = #selector(openTerminal(_:))
        for view in [operationButtons[.abortRebase], terminalButton].compactMap(\.self) {
            rebaseRow.addArrangedSubview(view)
        }
        rebaseRow.spacing = 8

        outputView.isEditable = false
        outputView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        outputView.textContainerInset = NSSize(width: 4, height: 4)
        let scroll = NSScrollView()
        scroll.documentView = outputView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        outputView.autoresizingMask = [.width]
        statusLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [facts, row, rebaseRow, scroll, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        return stack
    }

    // MARK: Rendering

    func render() {
        let status = sync.status
        branchLabel.stringValue = status.map { $0.branch ?? "(detached HEAD)" } ?? "…"
        upstreamLabel.stringValue = status.map { $0.upstream ?? "none" } ?? "…"
        stateLabel.stringValue = status.map(Self.describe) ?? "…"
        fetchedLabel.stringValue = sync.lastFetch.map(dateFormatter.string(from:)) ?? "never"
        for (operation, button) in operationButtons {
            button.isEnabled = sync.canRun(operation)
        }
        rebaseRow.isHidden = !sync.isRebasing
        terminalButton.isEnabled = sync.isRebasing
        cancelButton.isEnabled = sync.running != nil
        if outputView.string != sync.output {
            outputView.string = sync.output
            outputView.scrollToEndOfDocument(nil)
        }
        let (text, failed) = Self.statusLine(sync)
        statusLabel.stringValue = text
        statusLabel.textColor = failed ? .systemRed : .secondaryLabelColor
    }

    static func describe(_ status: GitRepoStatus) -> String {
        guard status.upstream != nil else {
            return "no upstream: Pull and Push need one"
        }
        switch (status.ahead, status.behind) {
        case (0, 0): return "up to date with its upstream"
        case let (ahead, 0): return "\(ahead) to push"
        case let (0, behind): return "\(behind) to pull"
        case let (ahead, behind): return "\(ahead) to push, \(behind) to pull"
        }
    }

    static func statusLine(_ sync: GitSync) -> (String, failed: Bool) {
        if let problem = sync.problem {
            return (problem, true)
        }
        if let running = sync.running {
            return ("\(running.title)…", false)
        }
        if sync.isRebasing {
            return ("A rebase has stopped, most likely on a conflict: abort it, or finish it in the terminal.", true)
        }
        switch sync.outcome {
        case let .succeeded(operation): return ("\(operation.title) done.", false)
        case let .failed(operation, message): return ("\(operation.title) failed: \(message)", true)
        case let .cancelled(operation): return ("\(operation.title) cancelled.", false)
        case nil: return ("", false)
        }
    }

    // MARK: Input

    @objc private func runOperation(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue, let operation = GitSync.Operation(rawValue: name) else {
            return
        }
        sync.perform(.run(operation))
    }

    @objc private func cancelRunning(_: Any?) {
        sync.perform(.cancel)
    }

    @objc private func openTerminal(_: Any?) {
        sync.perform(.openTerminal)
    }

    /// Back from the terminal (or anywhere): what happened there shows, a rebase finished or
    /// aborted there included (#45 review).
    func windowDidBecomeKey(_: Notification) {
        sync.perform(.refresh)
    }
}
