/// What a later launch restores: each side's folder and sort order, whether hidden files are
/// shown, and the tree's favorites. (Window frame, splitters and columns are saved by AppKit's autosave.)
public struct WorkspaceState: Codable, Equatable, Sendable {
    public struct SideSettings: Codable, Equatable, Sendable {
        public var location: String
        public var sort: ListSort
        /// The file list's columns if the user changed them (#25), else nil. Names, so a column
        /// a later version drops cannot make the whole state unreadable.
        public var columns: [String]?
        /// The recent folders strip (#74); nil in a state saved before it.
        public var recentFolders: RecentFolders?

        public init(location: String, sort: ListSort, columns: [String]? = nil, recentFolders: RecentFolders? = nil) {
            self.location = location
            self.sort = sort
            self.columns = columns
            self.recentFolders = recentFolders
        }
    }

    public var left: SideSettings
    public var right: SideSettings
    public var showsHiddenFiles: Bool
    /// The tree's favorites; nil (a state saved before they could change) means the defaults.
    public var favorites: [String]?

    public init(left: SideSettings, right: SideSettings, showsHiddenFiles: Bool, favorites: [String]? = nil) {
        self.left = left
        self.right = right
        self.showsHiddenFiles = showsHiddenFiles
        self.favorites = favorites
    }
}

public extension Workspace {
    /// The state to save for the next launch.
    var savedState: WorkspaceState {
        func settings(_ side: Side) -> WorkspaceState.SideSettings {
            let state = state(of: side)
            return WorkspaceState.SideSettings(location: state.location, sort: state.sort,
                                               columns: state.columns.map(ListColumn.names(of:)),
                                               recentFolders: state.recentFolders == RecentFolders() ? nil
                                                   : state.recentFolders)
        }
        // Left out while they are the defaults, so a later version's defaults reach whoever never
        // changed them.
        let changed = stateFavorites == TreeRoots.defaultFavorites(home: home) ? nil : stateFavorites
        return WorkspaceState(left: settings(.left), right: settings(.right), showsHiddenFiles: showsHiddenFiles,
                              favorites: changed)
    }
}

extension SideState {
    init(restoring settings: WorkspaceState.SideSettings) {
        self.init(location: settings.location)
        columns = settings.columns.map(ListColumn.set(named:))
        // A sort by a column that turns out hidden (Kind, by default since #13) becomes the
        // default sort once the settings are known: `Workspace.keepSortVisible` (#25).
        sort = settings.sort
        recentFolders = settings.recentFolders ?? RecentFolders()
        fallsBackToHome = true
    }
}
