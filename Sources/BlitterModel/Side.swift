import BlitterCore

/// One of the two side-by-side listers.
public enum Side: CaseIterable, Sendable {
    case left
    case right

    /// The side across from this one. When this side is the source, that is the destination.
    public var opposite: Side {
        switch self {
        case .left: .right
        case .right: .left
        }
    }
}

/// Whether a side's folder is being read, was read, or could not be read.
public enum LoadStatus: Equatable, Sendable {
    case loading
    case loaded
    case failed(String)
}

/// State of a single side.
public struct SideState: Sendable {
    /// Absolute path of the folder this side shows.
    public internal(set) var location: String
    public internal(set) var status: LoadStatus = .loading
    /// Everything in the folder, unsorted, including hidden items.
    var allEntries: [DirectoryEntry] = []
    /// What the file list shows: hidden items filtered out (unless shown), sorted.
    public internal(set) var visibleEntries: [ListedEntry] = []
    public internal(set) var sort = ListSort()
    /// Names of the selected entries. Names stay valid across reloads, row indexes do not.
    public internal(set) var selection: Set<String> = []
    /// Increases whenever `visibleEntries` is replaced, so views can tell a new listing from a
    /// selection change and reload only when needed.
    public internal(set) var entriesVersion = 0
}
