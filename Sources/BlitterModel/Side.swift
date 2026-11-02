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
    /// Absolute path of the folder this side shows, or is about to show while it is being read.
    public internal(set) var location: String
    /// The folder `visibleEntries` belong to. After a navigation it still names the previous
    /// folder until the new listing arrives, so the old rows stay usable until they are replaced.
    public internal(set) var entriesLocation: String
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
    /// Folders to go back to, the most recent last.
    public internal(set) var backStack: [String] = []
    /// Folders to go forward to after going back, the next one last.
    public internal(set) var forwardStack: [String] = []
    /// Folders this side visited, the most recent first, without duplicates. The path field's
    /// dropdown offers them.
    public internal(set) var recentLocations: [String]
    /// An entry to select once the listing of its folder contains it: the folder we came up from,
    /// or one a job created or renamed. Bound to its folder, so it never selects a same-named
    /// entry elsewhere; navigation drops it.
    var pendingSelection: PendingSelection?
    /// A folder action chosen in the tree's menu while that folder was still being read; it runs
    /// when the listing arrives. Navigation drops it, so it never runs anywhere else.
    var pendingAction: PendingAction?
    /// The entry whose name the view should edit in place, in the folder it belongs to. The token
    /// changes with every request, so the view can tell a new request from one it already started.
    public internal(set) var renameRequest: RenameRequest?
    /// The file list's columns once the user showed or hid one here (#25); nil follows the
    /// settings file. Saved for the next launch.
    public internal(set) var columns: Set<ListColumn>?
    /// Expanded folders, loaded subfolders and the selection of this side's folder tree.
    public internal(set) var tree = FolderTreeState()

    /// Set for a folder restored from the last session: if its first listing fails (the folder is
    /// gone, its volume unmounted), the side starts at the home folder instead.
    var fallsBackToHome = false

    init(location: String) {
        self.location = location
        entriesLocation = location
        recentLocations = [location]
    }

    public var canGoBack: Bool {
        !backStack.isEmpty
    }

    public var canGoForward: Bool {
        !forwardStack.isEmpty
    }

    public var canGoToParent: Bool {
        location != "/"
    }
}

public struct RenameRequest: Equatable, Sendable {
    public let name: String
    /// The folder the entry is in; the view edits only while it shows that folder.
    public let folder: String
    public let token: Int

    public var path: String {
        Paths.appending(name, to: folder)
    }
}

struct PendingSelection: Equatable {
    let folder: String
    let name: String
}

struct PendingAction: Equatable {
    let folder: String
    let id: String
}
