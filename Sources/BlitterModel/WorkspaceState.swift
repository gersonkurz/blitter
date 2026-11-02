/// What a later launch restores: each side's folder and sort order, and whether hidden files are
/// shown. (Window frame, splitters and columns are saved by AppKit's autosave.)
public struct WorkspaceState: Codable, Equatable, Sendable {
    public struct SideSettings: Codable, Equatable, Sendable {
        public var location: String
        public var sort: ListSort
        /// The file list's columns if the user changed them (#25), else nil. Names, so a column
        /// a later version drops cannot make the whole state unreadable.
        public var columns: [String]?

        public init(location: String, sort: ListSort, columns: [String]? = nil) {
            self.location = location
            self.sort = sort
            self.columns = columns
        }
    }

    public var left: SideSettings
    public var right: SideSettings
    public var showsHiddenFiles: Bool

    public init(left: SideSettings, right: SideSettings, showsHiddenFiles: Bool) {
        self.left = left
        self.right = right
        self.showsHiddenFiles = showsHiddenFiles
    }
}

public extension Workspace {
    /// The state to save for the next launch.
    var savedState: WorkspaceState {
        func settings(_ side: Side) -> WorkspaceState.SideSettings {
            let state = state(of: side)
            return WorkspaceState.SideSettings(location: state.location, sort: state.sort,
                                               columns: state.columns.map(ListColumn.names(of:)))
        }
        return WorkspaceState(left: settings(.left), right: settings(.right), showsHiddenFiles: showsHiddenFiles)
    }
}

extension SideState {
    init(restoring settings: WorkspaceState.SideSettings) {
        self.init(location: settings.location)
        columns = settings.columns.map(ListColumn.set(named:))
        // A sort by a column that turns out hidden (Kind, by default since #13) becomes the
        // default sort once the settings are known: `Workspace.keepSortVisible` (#25).
        sort = settings.sort
        fallsBackToHome = true
    }
}
