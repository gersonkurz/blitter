import AppKit
import BlitterModel

/// The columns' widths (#123): `ColumnLayout` decides them from the room there is, each column's
/// preferred width (as dragged — kept across launches — or its default) and its fitted width (what
/// its content needs in the current font and date pattern). Laid out again when the list's width,
/// the columns shown, the fonts or the date pattern change, and when the user drags a column.
extension FileListViewController {
    static let defaultWidths: [ListColumn: CGFloat] = [
        .name: 280, .size: 80, .modified: 150, .kind: 140, .permissions: 90, .git: 90,
    ]

    /// The text's insets in a cell plus room for the column separator.
    static let cellPadding: CGFloat = 10

    /// Where a side's preferred widths are kept: nil in tests and profiles (as the table's own
    /// layout).
    static func preferredWidthsStore(_ side: Side) -> PreferredWidthsStore? {
        AppEnvironment.autosaveName(columnsAutosaveName(side) + "-preferred").map {
            PreferredWidthsStore(defaults: .standard, key: $0)
        }
    }

    /// The preferred widths: saved ones; else, the first time, the widths AppKit restored (what
    /// the user had dragged before #123) — but Name's default, as its restored width held the
    /// room left over. Those are saved at once: AppKit's own autosave keeps the laid-out widths
    /// from now on, which a narrow window has cut.
    func loadPreferredWidths() {
        if let saved = preferredWidthsStore?.load() {
            preferredWidths = saved
            return
        }
        for column in tableView.tableColumns {
            preferredWidths[column.identifier.rawValue] = column.identifier == Self.nameColumn
                ? Self.defaultWidths[.name] : column.width
        }
        preferredWidthsStore?.save(preferredWidths)
    }

    /// A column the user dragged keeps that width as its preferred one; the others make room.
    func tableViewColumnDidResize(_ notification: Notification) {
        guard !isLayingOutColumns, let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn else {
            return
        }
        preferredWidths[column.identifier.rawValue] = column.width
        preferredWidthsStore?.save(preferredWidths)
        layoutColumns()
    }

    /// The shown columns at their widths for the room there is now.
    func layoutColumns() {
        let shown = tableView.tableColumns.filter { !$0.isHidden }
        let spacing = tableView.intercellSpacing.width * CGFloat(shown.count)
        let available = (tableView.enclosingScrollView?.contentView.bounds.width ?? tableView.bounds.width) - spacing
        guard available > 0 else {
            return
        }
        let columns = shown.compactMap { column -> ColumnLayout.Column? in
            guard let listColumn = ListColumn(rawValue: column.identifier.rawValue) else {
                return nil
            }
            let role: ColumnLayout.Role = switch listColumn {
            case .name: .name
            case .kind: .text
            case .size, .modified, .permissions, .git: .fitted
            }
            let preferred = preferredWidths[column.identifier.rawValue] ?? Self.defaultWidths[listColumn] ?? 100
            return ColumnLayout.Column(id: column.identifier.rawValue, role: role, preferred: preferred,
                                       fitted: fittedWidth(listColumn, column), minimum: column.minWidth)
        }
        let widths = ColumnLayout.widths(columns, available: available)
        isLayingOutColumns = true
        defer { isLayingOutColumns = false }
        for column in shown {
            if let width = widths[column.identifier.rawValue], abs(column.width - width) >= 0.5 {
                column.width = width.rounded(.down)
            }
        }
    }

    /// What the column's content needs in the current font, its header's title included.
    func fittedWidth(_ listColumn: ListColumn, _ column: NSTableColumn) -> CGFloat {
        func widest(_ texts: [String], _ font: NSFont) -> CGFloat {
            texts.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        }
        let content: CGFloat = switch listColumn {
        case .size:
            widest(Formatting.wideSampleSizes.map(Formatting.byteCount) + ["--", "…"], fonts.tabular)
        case .modified:
            widest(Formatting.wideSampleDates.map(dateFormatter.string(from:)), fonts.mono)
        case .permissions:
            widest(["rwxrwxrwx"], fonts.mono)
        case .git:
            widest([GitItemStatus.unchanged, .modified, .untracked, .ignored, .aheadOrBehind(ahead: 99, behind: 99)]
                .map(Self.text(of:)), fonts.text)
        case .name, .kind:
            0
        }
        let header = column.headerCell.cellSize.width + 12 // room for the sort arrow
        return ceil(max(content + Self.cellPadding, header))
    }
}

/// The preferred column widths of one side, kept across launches (#123).
struct PreferredWidthsStore {
    let defaults: UserDefaults
    let key: String

    func load() -> [String: CGFloat]? {
        (defaults.dictionary(forKey: key) as? [String: Double])?.mapValues { CGFloat($0) }
    }

    func save(_ widths: [String: CGFloat]) {
        defaults.set(widths.mapValues { Double($0) }, forKey: key)
    }
}
