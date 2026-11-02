import AppKit
import BlitterCore
import BlitterGit
import BlitterModel

/// The Git Log window (#42): a filter, the commits, and the files the selected one changed. A
/// double-click (or Return) on a file shows it before and after in the diff tool.
@MainActor
final class GitLogWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate
{
    let log: GitLog
    let filterField = NSSearchField()
    let statusLabel = NSTextField(labelWithString: "")
    let commitsTable = NSTableView()
    let changesTable = ActivatingTableView()
    private var renderedCommits: [GitCommit] = []
    private var renderedChanges: [GitChange]? = []
    private var isRendering = false
    private let dateFormatter: DateFormatter

    init(workspace: Workspace, path: String, access: GitHistoryAccess = .real) {
        log = GitLog(workspace: workspace, path: path, access: access)
        dateFormatter = Formatting.dateFormatter(workspace.settings.dateFormat)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
                              defer: false)
        window.title = "Git Log — " + (log.relativePath ?? (path as NSString).lastPathComponent)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = makeContent()
        window.center()
        log.onChange = { [weak self] in self?.render() }
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Layout

    private func makeContent() -> NSView {
        filterField.placeholderString = "Filter by message, author or hash"
        filterField.sendsSearchStringImmediately = true
        filterField.delegate = self
        statusLabel.textColor = .secondaryLabelColor
        configure(commitsTable, columns: [Column("subject", "Message", 460), Column("author", "Author", 160),
                                          Column("date", "Date", 140), Column("hash", "Hash", 90)])
        configure(changesTable, columns: [Column("status", "", 28), Column("path", "File", 700)])
        changesTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle // the file takes the room
        changesTable.target = self
        changesTable.doubleAction = #selector(compareClicked(_:))
        changesTable.onReturn = { [weak self] in self?.compareSelected() }

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(scrolling(commitsTable))
        split.addArrangedSubview(scrolling(changesTable))
        split.setHoldingPriority(.defaultLow - 1, forSubviewAt: 0)

        let root = NSView()
        for view in [filterField, statusLabel, split] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            filterField.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            filterField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            filterField.widthAnchor.constraint(equalToConstant: 340),
            statusLabel.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: filterField.trailingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -10),
            split.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 10),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            changesTable.enclosingScrollView?.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ].compactMap(\.self))
        return root
    }

    private struct Column {
        let id: String
        let title: String
        let width: CGFloat

        init(_ id: String, _ title: String, _ width: CGFloat) {
            (self.id, self.title, self.width) = (id, title, width)
        }
    }

    private func configure(_ table: NSTableView, columns: [Column]) {
        for spec in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            table.addTableColumn(column)
        }
        table.style = .fullWidth
        table.rowSizeStyle = .small
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
    }

    private func scrolling(_ table: NSTableView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    // MARK: Rendering

    func render() {
        isRendering = true
        defer { isRendering = false }
        statusLabel.textColor = log.problem == nil ? .secondaryLabelColor : .systemRed
        let status = switch log.status {
        case .loading: "Reading the history…"
        case let .failed(message): message
        case let .loaded(truncated):
            (log.shown.count == log.commits.count ? "\(log.commits.count) commits"
                : "\(log.shown.count) of \(log.commits.count) commits")
                + (truncated ? " (the latest \(GitLog.limit.formatted()))" : "")
        }
        statusLabel.stringValue = log.problem ?? status
        if log.shown != renderedCommits {
            renderedCommits = log.shown
            commitsTable.reloadData()
        }
        let row = log.selected.flatMap { selected in renderedCommits.firstIndex { $0.hash == selected.hash } }
        if commitsTable.selectedRowIndexes != (row.map { IndexSet(integer: $0) } ?? IndexSet()) {
            commitsTable.selectRowIndexes(row.map { IndexSet(integer: $0) } ?? IndexSet(), byExtendingSelection: false)
        }
        if log.changes != renderedChanges {
            renderedChanges = log.changes
            changesTable.reloadData()
        }
    }

    // MARK: Input

    func controlTextDidChange(_: Notification) {
        log.perform(.filter(filterField.stringValue))
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRendering, notification.object as? NSTableView === commitsTable else {
            return
        }
        let row = commitsTable.selectedRow
        log.perform(.select(row >= 0 && row < renderedCommits.count ? renderedCommits[row].hash : nil))
    }

    @objc private func compareClicked(_: Any?) {
        compare(row: changesTable.clickedRow)
    }

    private func compareSelected() {
        compare(row: changesTable.selectedRow)
    }

    private func compare(row: Int) {
        guard let changes = renderedChanges, row >= 0, row < changes.count else {
            return
        }
        log.perform(.compare(changes[row]))
    }

    // MARK: Data source

    func numberOfRows(in table: NSTableView) -> Int {
        table === commitsTable ? renderedCommits.count : renderedChanges?.count ?? 0
    }

    func tableView(_ table: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column else {
            return nil
        }
        let cell = table.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView
            ?? Self.makeCell(column.identifier)
        cell.textField?.stringValue = text(table, column.identifier.rawValue, row)
        return cell
    }

    private func text(_ table: NSTableView, _ column: String, _ row: Int) -> String {
        if table === commitsTable {
            guard row < renderedCommits.count else {
                return ""
            }
            let commit = renderedCommits[row]
            return switch column {
            case "subject": commit.subject
            case "author": commit.author
            case "date": dateFormatter.string(from: commit.date)
            default: String(commit.hash.prefix(10))
            }
        }
        guard let changes = renderedChanges, row < changes.count else {
            return ""
        }
        let change = changes[row]
        return column == "status" ? change.status
            : change.oldPath.map { "\($0) → \(change.path)" } ?? change.path
    }

    private static func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = identifier.rawValue == "hash" ? MonospacedTextField(labelWithString: "")
            : NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
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
