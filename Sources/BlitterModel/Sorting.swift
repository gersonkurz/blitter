import BlitterCore
import Foundation
import UniformTypeIdentifiers

/// Columns the file list can be sorted by.
public enum SortColumn: String, CaseIterable, Codable, Sendable {
    case name
    case size
    case modified
    case kind
    case permissions
}

public struct ListSort: Equatable, Codable, Sendable {
    public var column: SortColumn = .name
    public var ascending = true

    public init(column: SortColumn = .name, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }
}

/// A directory entry together with its content type and kind description ("Folder", "PDF
/// document"...). The Kind column shows and sorts by the description; the icon follows the type.
public struct ListedEntry: Sendable {
    public let entry: DirectoryEntry
    public let contentType: UTType
    public let kindDescription: String
}

enum Listing {
    /// A folder's entries, what the list shows of them, and where each shown name is: built in
    /// the background, so the main thread never searches the listing for a name (#47).
    struct Result: Sendable {
        let all: [DirectoryEntry]
        let visible: [ListedEntry]
        let index: [String: Int]
        let totals: EntryTotals

        init(all: [DirectoryEntry], visible: [ListedEntry]) {
            self.all = all
            self.visible = visible
            totals = EntryTotals(visible)
            var index: [String: Int] = [:]
            index.reserveCapacity(visible.count)
            for (row, listed) in visible.enumerated() {
                index[listed.entry.name] = row
            }
            self.index = index
        }
    }

    /// Filters and sorts a folder's entries for display. Folders always come first, in both sort
    /// directions; ties are broken by name so the order is stable. Runs off the main thread.
    /// `filter` is the fast filter's text in filter mode (#39): only matching names are listed.
    static func visibleEntries(_ entries: [DirectoryEntry], showHidden: Bool, sort: ListSort,
                               filter: String? = nil) -> [ListedEntry]
    {
        var types = ContentTypes()
        let matcher = filter.flatMap { $0.isEmpty ? nil : QuickFilter.Matcher($0) }
        var listed = entries.compactMap { entry -> ListedEntry? in
            guard showHidden || !entry.isHidden, matcher?.matches(entry.name) ?? true else {
                return nil
            }
            let (type, description) = types.classify(entry)
            return ListedEntry(entry: entry, contentType: type, kindDescription: description)
        }
        // Few distinct kinds, many entries: rank the kinds once and compare integers while sorting.
        var kindRank: [String: Int] = [:]
        if sort.column == .kind {
            let kinds = Set(listed.map(\.kindDescription))
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            kindRank = Dictionary(uniqueKeysWithValues: kinds.enumerated().map { ($1, $0) })
        }
        listed.sort { lhs, rhs in
            let lhsIsFolder = lhs.entry.kind == .directory
            if lhsIsFolder != (rhs.entry.kind == .directory) {
                return lhsIsFolder
            }
            var order: ComparisonResult = switch sort.column {
            case .name: .orderedSame // compared below
            case .size: compareValues(lhs.entry.size, rhs.entry.size)
            case .modified: compareValues(lhs.entry.modificationDate, rhs.entry.modificationDate)
            case .kind: compareValues(kindRank[lhs.kindDescription] ?? 0, kindRank[rhs.kindDescription] ?? 0)
            case .permissions: compareValues(lhs.entry.permissions, rhs.entry.permissions)
            }
            if order == .orderedSame {
                order = lhs.entry.name.localizedStandardCompare(rhs.entry.name)
            }
            return sort.ascending ? order == .orderedAscending : order == .orderedDescending
        }
        return listed
    }

    private static func compareValues<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
    }
}

/// Content type and kind description from the name and kind alone, without disk access, looked up
/// once per extension. A folder only gets a special type when its extension is registered for a
/// folder type (apps, bundles); an ordinary folder named "archive.pdf" stays a "Folder".
struct ContentTypes {
    private typealias Classification = (type: UTType, description: String)
    private var byKindAndExtension: [String: Classification] = [:]

    mutating func classify(_ entry: DirectoryEntry) -> (type: UTType, description: String) {
        switch entry.kind {
        case .directory: lookup(entry.name, conformingTo: .directory, fallback: (.folder, "Folder"))
        case .file: lookup(entry.name, conformingTo: .data, fallback: (.data, "Document"))
        case .symlink: (.symbolicLink, "Alias")
        case .other: (.item, "Special file")
        }
    }

    private mutating func lookup(_ name: String, conformingTo base: UTType,
                                 fallback: Classification) -> Classification
    {
        let pathExtension = (name as NSString).pathExtension.lowercased()
        guard !pathExtension.isEmpty else {
            return fallback
        }
        let key = base.identifier + "/" + pathExtension
        if let cached = byKindAndExtension[key] {
            return cached
        }
        // Unknown extensions give a dynamic type, which says nothing useful.
        var result = fallback
        if let type = UTType(filenameExtension: pathExtension, conformingTo: base), !type.isDynamic {
            result = (type, type.localizedDescription ?? fallback.description)
        }
        byKindAndExtension[key] = result
        return result
    }
}
