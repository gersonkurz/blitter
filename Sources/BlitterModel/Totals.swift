import BlitterCore

/// How many folders and files a set of entries holds, and how big the files are together: what
/// the status line below a file list shows (#51).
public struct EntryTotals: Equatable, Sendable {
    public private(set) var folders = 0
    /// Everything that is not a folder: files, links and the rest.
    public private(set) var files = 0
    /// The files' sizes added up. Folders add nothing: their size is not known.
    public private(set) var bytes: Int64 = 0

    public init() {}

    init(_ entries: some Sequence<ListedEntry>) {
        for listed in entries {
            if listed.entry.kind == .directory {
                folders += 1
            } else {
                files += 1
                bytes += listed.entry.size
            }
        }
    }

    public var count: Int {
        folders + files
    }
}

/// The free space on the volume of a folder, read in the background (#51).
public struct FreeSpace: Equatable, Sendable {
    public let folder: String
    public let bytes: Int64
}
