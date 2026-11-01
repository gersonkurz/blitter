import BlitterCore

/// Keeps both sides and their trees in step with the disk: the folders they show are watched,
/// and a change reads the affected folders again. Reading again keeps the selection (by name)
/// and shows the old contents until the new ones arrive.
extension Workspace {
    /// Every state change goes through here, so the watched folders always match what is shown.
    func notifyChange() {
        updateWatchedFolders()
        onChange?()
    }

    /// The sides' folders and every expanded tree folder. A folder is watched from the moment it
    /// is shown or expanded, before it is read, so a change while it is being read is not missed.
    /// `retry`: hand the set over even if it is unchanged, so the watcher tries again folders it
    /// could not open before (one that has just been created).
    func updateWatchedFolders(retry: Bool = false) {
        var folders: Set<String> = []
        for state in sides.values {
            folders.insert(state.location)
            folders.formUnion(state.tree.expanded.map(\.path))
        }
        if let settingsFolder {
            folders.insert(settingsFolder)
        }
        guard folders != watchedFolders || retry else {
            return
        }
        // Changes to folders nobody watches go unnoticed: their cached subfolders cannot be trusted.
        for folder in watchedFolders.subtracting(folders) {
            for side in Side.allCases where sides[side]?.tree.children[folder] != nil {
                sides[side]?.tree.stale.insert(folder)
            }
        }
        watchedFolders = folders
        watcher?.watch(folders)
    }

    func foldersChanged(_ changes: [FolderChange]) {
        if let settingsFolder, changes.contains(where: { $0.affects(settingsFolder) }) {
            loadSettings()
        }
        for side in Side.allCases {
            guard let state = sides[side] else {
                continue
            }
            if changes.contains(where: { $0.affects(state.location) }) {
                load(side)
            }
            // A read still running may have looked at the folder before the change: start over.
            for (path, children) in state.tree.children where children != .failed {
                if changes.contains(where: { $0.affects(path) }) {
                    loadTreeChildren(side, path, again: true)
                }
            }
        }
    }
}

extension FolderChange {
    /// Whether the contents of `folder` may have changed.
    func affects(_ folder: String) -> Bool {
        path == folder || (includesSubfolders && Paths.contains(folder, in: path))
    }
}
