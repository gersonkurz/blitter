/// The file list's columns (#25). Name is always shown; the others are shown or hidden per side,
/// from the header's context menu. A side that was never changed shows the settings file's
/// `columns`; their order and widths are the table's own (dragged in the header).
public enum ListColumn: String, CaseIterable, Sendable {
    case name
    case size
    case modified
    case kind
    case permissions
    case git

    /// What a click on its header sorts by. Git states arrive after the listing, so sorting by
    /// them would reorder the rows under the user: that column does not sort.
    public var sortColumn: SortColumn? {
        switch self {
        case .name: .name
        case .size: .size
        case .modified: .modified
        case .kind: .kind
        case .permissions: .permissions
        case .git: nil
        }
    }

    /// Shown unless the settings file or the side says otherwise (Kind is not, #13).
    public static let defaults: Set<ListColumn> = [.name, .size, .modified]

    /// The columns with these names, Name always among them; unknown names are skipped.
    static func set(named names: [String]) -> Set<ListColumn> {
        Set(names.compactMap(ListColumn.init(rawValue:))).union([.name])
    }

    /// The names of these columns in their standard order, for the settings and the saved state.
    static func names(of columns: Set<ListColumn>) -> [String] {
        allCases.filter(columns.contains).map(\.rawValue)
    }
}

public extension Workspace {
    /// The columns the side shows: its own once the user changed them, else the settings'.
    func columns(of side: Side) -> Set<ListColumn> {
        state(of: side).columns ?? settings.columns
    }
}

extension Workspace {
    func showColumn(_ side: Side, _ column: ListColumn, _ shown: Bool) -> Bool {
        var columns = columns(of: side)
        guard column != .name, columns.contains(column) != shown else {
            return false
        }
        if shown {
            columns.insert(column)
        } else {
            columns.remove(column)
        }
        sides[side]?.columns = columns
        keepSortVisible(side)
        return true
    }

    /// The side follows the settings' columns again.
    func resetColumns(_ side: Side) -> Bool {
        guard sides[side]?.columns != nil else {
            return false
        }
        sides[side]?.columns = nil
        keepSortVisible(side)
        return true
    }

    /// A list sorted by a column it does not show would be sorted by something invisible: it
    /// goes back to the default sort, by name. Checked whenever the side's columns change: by
    /// the header's menu, and whenever the settings are read (#25 review). Returns whether it did.
    @discardableResult
    func keepSortVisible(_ side: Side) -> Bool {
        guard sortsByHiddenColumn(side) else {
            return false
        }
        _ = sort(side, ListSort())
        return true
    }

    func sortsByHiddenColumn(_ side: Side) -> Bool {
        guard let sorted = sides[side]?.sort.column else {
            return false
        }
        return !columns(of: side).contains { $0.sortColumn == sorted }
    }
}
