import BlitterCore
import Foundation
import UniformTypeIdentifiers

/// Columns the file list can be sorted by.
public enum SortColumn: String, CaseIterable, Sendable {
    case name
    case size
    case modified
    case kind
}

public struct ListSort: Equatable, Sendable {
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
    /// Filters and sorts a folder's entries for display. Folders always come first, in both sort
    /// directions; ties are broken by name so the order is stable. Runs off the main thread.
    static func visibleEntries(_ entries: [DirectoryEntry], showHidden: Bool, sort: ListSort) -> [ListedEntry] {
        var types = ContentTypes()
        var listed = entries.compactMap { entry -> ListedEntry? in
            guard showHidden || !entry.isHidden else {
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
