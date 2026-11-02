import AppKit
import BlitterCore
import BlitterModel
import UniformTypeIdentifiers

/// One side's file list: a path field with the recent folders and a detail table. It renders the
/// side's state from the workspace and turns user input into workspace commands.
@MainActor
final class FileListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSComboBoxDelegate
{
    let workspace: Workspace
    let side: Side
    /// The general pasteboard; tests use one of their own, so they never touch the user's clipboard.
    var pasteboard = NSPasteboard.general
    private let pathField = ActivatingComboBox()
    private(set) lazy var navigationButtons = NavigationButtons(side: side)
    let statusLabel = NSTextField(labelWithString: "")
    let tableView = ActivatingTableView()
    private var renderedVersion = -1
    private(set) var entries: [ListedEntry] = []
    /// The folder `entries` belong to.
    private(set) var location = ""
    private var renderedRecentLocations: [String] = []
    lazy var inlineRename = makeInlineRename()
    /// The rename request the view has already started editing for.
    var handledRenameToken: Int?
    var renderedPreviewPaths: [String] = []
    /// Called when the selected paths change; reloads an open Quick Look panel. Tests count it.
    lazy var previewItemsChanged: () -> Void = { [weak self] in self?.quickLookSelectionChanged() }
    private var isRendering = false
    private let icons: FileIcons
    /// The settings' date pattern the Date Modified column shows; "" until the first render.
    var renderedDateFormat = ""
    /// The colors the list was last drawn with (#21); nil before the first render.
    var palette: Palette?
    /// The git status of each shown item by name (#22, #35, #25), and what it was computed from.
    var gitStates: [String: GitItemStatus] = [:]
    var renderedGit: (version: Int, entries: Int) = (-1, -1)
    var dateFormatter = DateFormatter()

    static let nameColumn = NSUserInterfaceItemIdentifier(SortColumn.name.rawValue)
    private static let sizeColumn = NSUserInterfaceItemIdentifier(SortColumn.size.rawValue)
    static let modifiedColumn = NSUserInterfaceItemIdentifier(SortColumn.modified.rawValue)

    init(workspace: Workspace, side: Side) {
        self.workspace = workspace
        self.side = side
        icons = FileIcons(side: side)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        configureTable()

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        configurePathField()
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0

        navigationButtons.onCommand = { [weak self] command in self?.workspace.perform(command) }
        let root = NSView()
        for subview in [navigationButtons, pathField, scrollView, statusLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            navigationButtons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            navigationButtons.centerYAnchor.constraint(equalTo: pathField.centerYAnchor),
            pathField.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            pathField.leadingAnchor.constraint(equalTo: navigationButtons.trailingAnchor, constant: 6),
            pathField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            scrollView.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        view = root
    }

    private func configurePathField() {
        pathField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathField.controlSize = .small
        pathField.completes = false
        pathField.numberOfVisibleItems = 20
        pathField.lineBreakMode = .byTruncatingHead
        // Navigate on Return or on picking a recent folder, never just because focus moved away.
        pathField.cell?.sendsActionOnEndEditing = false
        pathField.target = self
        pathField.action = #selector(pathEntered(_:))
        pathField.delegate = self
        pathField.onBecomeFirstResponder = { [weak self] in
            guard let self else {
                return
            }
            workspace.perform(.activate(side))
        }
    }

    /// "v2" since #13: the v0.1 layouts showed Kind, and AppKit would restore it; everyone starts
    /// once with the new default.
    static func columnsAutosaveName(_ side: Side) -> String {
        "FileList-v2-\(side)"
    }

    private func configureTable() {
        addColumns()
        tableView.autosaveName = AppEnvironment.autosaveName(Self.columnsAutosaveName(side))
        tableView.autosaveTableColumns = !AppEnvironment.isHostedTest
        tableView.style = .fullWidth
        tableView.rowSizeStyle = .small
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        // A wider list gives the room to the names.
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openClickedRow(_:))
        tableView.onReturn = { [weak self] in self?.openSelectedRow() }
        tableView.onSpace = { [weak self] in
            guard let self else {
                return
            }
            workspace.perform(.togglePreview(side))
        }
        configureDragAndDrop()
        configureContextMenu()
        tableView.onBecomeFirstResponder = { [weak self] in
            guard let self else {
                return
            }
            workspace.perform(.activate(side))
        }
    }

    // MARK: Rendering

    func render() {
        isRendering = true
        defer { isRendering = false }
        let state = workspace.state(of: side)
        let isActive = workspace.activeSide == side
        // Never overwrite what the user is typing.
        if pathField.currentEditor() == nil {
            pathField.stringValue = state.location
        }
        renderPalette()
        pathField.textColor = pathFieldColor(isActive: isActive)
        navigationButtons.render(state)
        if state.recentLocations != renderedRecentLocations {
            renderedRecentLocations = state.recentLocations
            pathField.removeAllItems()
            pathField.addItems(withObjectValues: state.recentLocations)
        }

        renderDateFormat(workspace.settings.dateFormat)
        renderColumns()

        let sortDescriptor = NSSortDescriptor(key: state.sort.column.rawValue, ascending: state.sort.ascending)
        if tableView.sortDescriptors.first != sortDescriptor {
            tableView.sortDescriptors = [sortDescriptor]
        }

        var folderChanged = false
        if state.entriesVersion != renderedVersion {
            renderedVersion = state.entriesVersion
            let previous = entries
            entries = state.visibleEntries
            if location != state.entriesLocation {
                icons.cancelPending()
                location = state.entriesLocation
                folderChanged = true
                tableView.reloadData()
            } else if let changes = RowChanges.between(previous, entries) {
                // The same folder read again (a change on disk, a refresh): update only what changed.
                tableView.apply(changes)
            } else {
                tableView.reloadData()
            }
        }
        renderGit() // after `entries` and `location` are the new listing's
        applySelection(state.selection)
        if folderChanged, !entries.isEmpty {
            // A new folder starts at the top, or at the folder we came up from.
            tableView.scrollRowToVisible(tableView.selectedRowIndexes.first ?? 0)
        }
        startRequestedRename(state.renameRequest)
        followSelectionInPreview()

        renderStatus(state.status)
    }

    private static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = switch identifier {
        case sizeColumn, modifiedColumn: TabularTextField(labelWithString: "")
        case permissionsColumn: MonospacedTextField(labelWithString: "")
        default: NSTextField(labelWithString: "")
        }
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        var constraints = [
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
        ]
        if identifier == nameColumn {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            constraints += [
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
            ]
        } else {
            constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
        }
        if identifier == sizeColumn {
            text.alignment = .right
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }
}

extension FileListViewController {
    func focusList() {
        view.window?.makeFirstResponder(tableView)
    }

    func focusPathField() {
        view.window?.makeFirstResponder(pathField)
    }

    // MARK: User input

    @objc private func pathEntered(_ sender: NSComboBox) {
        let typed = sender.stringValue
        // Hand focus back to the list first, so the field shows the resolved path afterwards.
        view.window?.makeFirstResponder(tableView)
        workspace.perform(.navigate(side, path: typed))
        pathField.stringValue = workspace.state(of: side).location
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else {
            return false
        }
        // Escape in the path field drops the edit.
        view.window?.makeFirstResponder(tableView)
        pathField.stringValue = workspace.state(of: side).location
        return true
    }

    @objc private func openClickedRow(_: Any?) {
        open(row: tableView.clickedRow)
    }

    private func openSelectedRow() {
        let rows = tableView.selectedRowIndexes
        if rows.count == 1, let row = rows.first {
            open(row: row)
        }
    }

    private func open(row: Int) {
        guard row >= 0, row < entries.count else {
            return
        }
        workspace.perform(.open(side, name: entries[row].entry.name))
    }

    private func applySelection(_ names: Set<String>) {
        guard selectedNames() != names else {
            return
        }
        var rows = IndexSet()
        for (row, listed) in entries.enumerated() where names.contains(listed.entry.name) {
            rows.insert(row)
        }
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
    }

    private func selectedNames() -> Set<String> {
        Set(tableView.selectedRowIndexes.lazy.filter { $0 < self.entries.count }.map { self.entries[$0].entry.name })
    }

    // MARK: NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in _: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column, row < entries.count else {
            return nil
        }
        let listed = entries[row]
        let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView
            ?? Self.makeCell(identifier: column.identifier)
        switch column.identifier {
        case Self.nameColumn:
            cell.textField?.stringValue = listed.entry.name
            let name = listed.entry.name
            let folder = location
            cell.imageView?.image = icons.icon(for: listed, in: folder) { [weak self] in
                self?.iconLoaded(for: name, in: folder)
            }
        case Self.sizeColumn:
            cell.textField?.stringValue = Formatting.size(of: listed.entry)
        case Self.modifiedColumn:
            cell.textField?.stringValue = dateFormatter.string(from: listed.entry.modificationDate)
        default:
            cell.textField?.stringValue = columnText(column.identifier, for: listed) ?? listed.kindDescription
        }
        cell.textField?.textColor = textColor(for: listed)
        return cell
    }

    private func iconLoaded(for name: String, in folder: String) {
        guard folder == location, let row = entries.firstIndex(where: { $0.entry.name == name }),
              let column = tableView.tableColumns.firstIndex(where: { $0.identifier == Self.nameColumn })
        else {
            return
        }
        tableView.reloadData(forRowIndexes: [row], columnIndexes: [column])
    }

    /// Type-to-select matches the start of the name.
    func tableView(_: NSTableView, typeSelectStringFor column: NSTableColumn?, row: Int) -> String? {
        guard column == nil || column?.identifier == Self.nameColumn, row < entries.count else {
            return nil
        }
        return entries[row].entry.name
    }

    func tableViewSelectionDidChange(_: Notification) {
        // Selection changes made while rendering mirror the model; they are not user input.
        guard !isRendering else {
            return
        }
        workspace.perform(.select(side, selectedNames()))
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange _: [NSSortDescriptor]) {
        guard !isRendering, let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key, let column = SortColumn(rawValue: key)
        else {
            return
        }
        workspace.perform(.sort(side, ListSort(column: column, ascending: descriptor.ascending)))
    }
}
