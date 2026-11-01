/// What a later launch restores: each side's folder and sort order, and whether hidden files are
/// shown. (Window frame, splitters and columns are saved by AppKit's autosave.)
public struct WorkspaceState: Codable, Equatable, Sendable {
    public struct SideSettings: Codable, Equatable, Sendable {
        public var location: String
        public var sort: ListSort

        public init(location: String, sort: ListSort) {
            self.location = location
            self.sort = sort
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
            return WorkspaceState.SideSettings(location: state.location, sort: state.sort)
        }
        return WorkspaceState(left: settings(.left), right: settings(.right), showsHiddenFiles: showsHiddenFiles)
    }
}

extension SideState {
    init(restoring settings: WorkspaceState.SideSettings) {
        self.init(location: settings.location)
        sort = settings.sort
        fallsBackToHome = true
    }
}
