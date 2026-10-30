import AppKit
import BlitterCore
import BlitterModel

/// How to turn the rows of one listing of a folder into those of the next without reloading the
/// table, so scroll position, selection and the cells of unchanged rows stay as they are.
struct RowChanges: Equatable {
    /// Rows to remove, as indexes into the old listing.
    var removed = IndexSet()
    /// Rows to insert, as indexes into the new listing.
    var inserted = IndexSet()
    /// Rows that stayed but show different attributes (size, date), as indexes into the new listing.
    var updated = IndexSet()

    /// Nil when updating is not worth it compared to a reload: more than `limit` rows come or go,
    /// or rows that stayed changed places relative to each other (a size change re-sorted them).
    /// Linear in the number of rows, so it is cheap even for very large folders.
    static func between(_ old: [ListedEntry], _ new: [ListedEntry], limit: Int = 1000) -> RowChanges? {
        var oldByName: [String: DirectoryEntry] = [:]
        oldByName.reserveCapacity(old.count)
        for listed in old {
            oldByName[listed.entry.name] = listed.entry
        }
        let newNames = Set(new.lazy.map(\.entry.name))
        var changes = RowChanges()
        var keptOld: [String] = []
        for (row, listed) in old.enumerated() {
            if newNames.contains(listed.entry.name) {
                keptOld.append(listed.entry.name)
            } else {
                changes.removed.insert(row)
            }
        }
        var keptIndex = 0
        for (row, listed) in new.enumerated() {
            guard let previous = oldByName[listed.entry.name] else {
                changes.inserted.insert(row)
                continue
            }
            guard keptIndex < keptOld.count, keptOld[keptIndex] == listed.entry.name else {
                return nil // moved
            }
            keptIndex += 1
            if previous != listed.entry {
                changes.updated.insert(row)
            }
        }
        return changes.removed.count + changes.inserted.count > limit ? nil : changes
    }
}

extension NSTableView {
    /// Applies `changes`; the data source must already return the new rows.
    func apply(_ changes: RowChanges) {
        beginUpdates()
        removeRows(at: changes.removed, withAnimation: [])
        insertRows(at: changes.inserted, withAnimation: [])
        endUpdates()
        if !changes.updated.isEmpty {
            reloadData(forRowIndexes: changes.updated, columnIndexes: IndexSet(integersIn: 0 ..< numberOfColumns))
        }
    }
}
