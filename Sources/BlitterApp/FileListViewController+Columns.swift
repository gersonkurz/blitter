import AppKit
import BlitterCore
import BlitterModel

/// The file list's columns (#25): which are shown is the workspace's per side; a right-click on
/// the header shows or hides them. Their order and widths are the table's, saved by AppKit.
extension FileListViewController {
    static let permissionsColumn = NSUserInterfaceItemIdentifier(ListColumn.permissions.rawValue)
    static let gitColumn = NSUserInterfaceItemIdentifier(ListColumn.git.rawValue)

    static func title(of column: ListColumn) -> String {
        switch column {
        case .name: "Name"
        case .size: "Size"
        case .modified: "Date Modified"
        case .kind: "Kind"
        case .permissions: "Permissions"
        case .git: "Git"
        }
    }

    /// Column identifiers are the column names, so a header click maps straight to a sort.
    func addColumns() {
        let shown = workspace.columns(of: side)
        for listColumn in ListColumn.allCases {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(listColumn.rawValue))
            column.title = Self.title(of: listColumn)
            column.width = switch listColumn {
            case .name: 280
            case .size: 80
            case .modified: 150
            case .kind: 140
            case .permissions, .git: 90
            }
            column.isHidden = !shown.contains(listColumn)
            column.minWidth = 40
            if let sort = listColumn.sortColumn {
                column.sortDescriptorPrototype = NSSortDescriptor(key: sort.rawValue, ascending: true)
            }
            if listColumn == .size {
                column.headerCell.alignment = .right
            }
            tableView.addTableColumn(column)
        }
        let menu = NSMenu()
        menu.delegate = self
        tableView.headerView?.menu = menu
    }

    /// Shows the side's columns; AppKit's saved layout may have others hidden or shown.
    func renderColumns() {
        let shown = workspace.columns(of: side)
        for column in tableView.tableColumns {
            let hidden = ListColumn(rawValue: column.identifier.rawValue).map { !shown.contains($0) } ?? true
            if column.isHidden != hidden {
                column.isHidden = hidden
            }
        }
    }

    // MARK: Making cells

    static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
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

    // MARK: The header's menu

    /// Every column but Name, checked if shown, and Default Columns (`menuNeedsUpdate`).
    func fillColumnsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let shown = workspace.columns(of: side)
        for column in ListColumn.allCases where column != .name {
            let item = menu.addItem(withTitle: Self.title(of: column), action: #selector(toggleColumn(_:)),
                                    keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.state = shown.contains(column) ? .on : .off
        }
        menu.addItem(.separator())
        let reset = menu.addItem(withTitle: "Default Columns", action: #selector(resetColumns(_:)), keyEquivalent: "")
        reset.target = self
    }

    @objc private func toggleColumn(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String, let column = ListColumn(rawValue: name) else {
            return
        }
        workspace.perform(.showColumn(side, column, item.state != .on))
    }

    @objc private func resetColumns(_: NSMenuItem) {
        workspace.perform(.resetColumns(side))
    }

    // MARK: Cells

    /// The text of the Permissions and Git columns.
    func columnText(_ identifier: NSUserInterfaceItemIdentifier, for listed: ListedEntry) -> String? {
        switch identifier {
        case Self.permissionsColumn: Self.permissions(listed.entry.permissions)
        case Self.gitColumn: gitStates[listed.entry.name].map(Self.text(of:)) ?? ""
        default: nil
        }
    }

    /// The permission bits as `ls -l` shows them: "rwxr-xr-x", with s/S and t/T for setuid,
    /// setgid and sticky.
    static func permissions(_ mode: UInt16) -> String {
        func triple(_ bits: UInt16, special: Bool, letter: Character) -> String {
            let execute: Character = switch (bits & 1 != 0, special) {
            case (true, true): letter
            case (false, true): Character(letter.uppercased())
            case (true, false): "x"
            case (false, false): "-"
            }
            return (bits & 4 != 0 ? "r" : "-") + (bits & 2 != 0 ? "w" : "-") + String(execute)
        }
        return triple(mode >> 6 & 7, special: mode & 0o4000 != 0, letter: "s")
            + triple(mode >> 3 & 7, special: mode & 0o2000 != 0, letter: "s")
            + triple(mode & 7, special: mode & 0o1000 != 0, letter: "t")
    }

    static func text(of status: GitItemStatus) -> String {
        switch status {
        case .unchanged: "Unchanged"
        case .modified: "Modified"
        case .untracked: "Untracked"
        case .ignored: "Ignored"
        case let .aheadOrBehind(ahead, behind):
            [ahead > 0 ? "↑\(ahead)" : nil, behind > 0 ? "↓\(behind)" : nil].compactMap(\.self).joined(separator: " ")
        }
    }
}

/// Every character the same width, so permissions line up from row to row.
final class MonospacedTextField: NSTextField {
    override var font: NSFont? {
        get { super.font }
        set {
            super.font = .monospacedSystemFont(ofSize: newValue?.pointSize ?? NSFont.systemFontSize, weight: .regular)
        }
    }
}
