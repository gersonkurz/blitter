import AppKit
import BlitterCore
import BlitterModel
import UniformTypeIdentifiers

/// One side's file list: a header with the location and a detail table. It renders the side's
/// state from the workspace and turns user input into workspace commands.
@MainActor
final class FileListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let workspace: Workspace
    private let side: Side
    private let locationLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let tableView = ActivatingTableView()
    private var renderedVersion = -1
    private var entries: [ListedEntry] = []
    /// The folder `entries` belong to.
    private var location = ""
    private var isRendering = false
    private let icons: FileIcons

    private static let nameColumn = NSUserInterfaceItemIdentifier(SortColumn.name.rawValue)
    private static let sizeColumn = NSUserInterfaceItemIdentifier(SortColumn.size.rawValue)
    private static let modifiedColumn = NSUserInterfaceItemIdentifier(SortColumn.modified.rawValue)

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

    var table: NSTableView {
        tableView
    }

    override func loadView() {
        configureTable()

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        locationLabel.lineBreakMode = .byTruncatingHead
        locationLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0

        let root = NSView()
        for subview in [locationLabel, scrollView, statusLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            locationLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            locationLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            locationLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: locationLabel.bottomAnchor, constant: 6),
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

    private func configureTable() {
        // Column identifiers are the SortColumn raw values, so a header click maps straight to a sort.
        for sortColumn in SortColumn.allCases {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(sortColumn.rawValue))
            switch sortColumn {
            case .name: (column.title, column.width) = ("Name", 280)
            case .size: (column.title, column.width) = ("Size", 80)
            case .modified: (column.title, column.width) = ("Date Modified", 150)
            case .kind: (column.title, column.width) = ("Kind", 140)
            }
            column.minWidth = 40
            column.sortDescriptorPrototype = NSSortDescriptor(key: sortColumn.rawValue, ascending: true)
            if sortColumn == .size {
                column.headerCell.alignment = .right
            }
            tableView.addTableColumn(column)
        }
        tableView.autosaveName = "FileList-\(side)"
        tableView.autosaveTableColumns = true
        tableView.style = .fullWidth
        tableView.rowSizeStyle = .small
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
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
        locationLabel.stringValue = state.location
        locationLabel.textColor = isActive ? .controlAccentColor : .secondaryLabelColor

        let sortDescriptor = NSSortDescriptor(key: state.sort.column.rawValue, ascending: state.sort.ascending)
        if tableView.sortDescriptors.first != sortDescriptor {
            tableView.sortDescriptors = [sortDescriptor]
        }

        if state.entriesVersion != renderedVersion {
            renderedVersion = state.entriesVersion
            entries = state.visibleEntries
            if location != state.location {
                icons.cancelPending()
                location = state.location
            }
            tableView.reloadData()
        }
        applySelection(state.selection)

        switch state.status {
        case .loading:
            statusLabel.stringValue = ""
        case .loaded:
            statusLabel.stringValue = entries.isEmpty ? "Empty folder" : ""
        case let .failed(message):
            statusLabel.stringValue = message
        }

        if isActive, let window = view.window, window.firstResponder !== tableView {
            window.makeFirstResponder(tableView)
        }
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
            cell.textField?.stringValue = Formatting.date(listed.entry.modificationDate)
        default:
            cell.textField?.stringValue = listed.kindDescription
        }
        cell.textField?.textColor = listed.entry.isHidden ? .secondaryLabelColor : .labelColor
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

    private static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
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

/// A table view that reports when it gains keyboard focus, which makes its side the active side.
final class ActivatingTableView: NSTableView {
    var onBecomeFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onBecomeFirstResponder?()
        }
        return accepted
    }
}

/// Icons for one side's file list. Every entry first gets its content type's icon, cached for the
/// whole app, which needs no disk access. Packages such as apps have their own icon; it is read in
/// the background, only when a cell asks for it, by a loader that belongs to this side alone.
@MainActor
final class FileIcons {
    private static var byType: [String: NSImage] = [:]
    private let packageIcons: PathLoader<NSImage>

    init(side: Side) {
        packageIcons = PathLoader(label: "Blitter.FileIcons.\(side)") { NSWorkspace.shared.icon(forFile: $0) }
    }

    func icon(for listed: ListedEntry, in folder: String, onLoaded: @escaping () -> Void) -> NSImage {
        if listed.contentType.conforms(to: .package) {
            let path = (folder as NSString).appendingPathComponent(listed.entry.name)
            if let icon = packageIcons.value(for: path, onLoaded: onLoaded) {
                return icon
            }
        }
        let identifier = listed.contentType.identifier
        if let cached = Self.byType[identifier] {
            return cached
        }
        let icon = NSWorkspace.shared.icon(for: listed.contentType)
        Self.byType[identifier] = icon
        return icon
    }

    /// Drops icon requests for a folder the side no longer shows.
    func cancelPending() {
        packageIcons.cancelAll()
    }
}

@MainActor
enum Formatting {
    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    static func size(of entry: DirectoryEntry) -> String {
        entry.kind == .directory ? "--" : sizeFormatter.string(fromByteCount: entry.size)
    }

    static func date(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}
