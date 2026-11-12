import Foundation

// MARK: Eject (#84)

public extension Workspace {
    /// The volume in the tree's Volumes that `path` is on, if it can be ejected: not the startup
    /// disk. The innermost one, should one volume be mounted inside another.
    func ejectableVolume(containing path: String) -> TreeRoot? {
        treeRoots.filter { root in
            guard case .volume(isRoot: false, _) = root.kind else {
                return false
            }
            return Paths.contains(path, in: root.path)
        }
        .max { $0.path.count < $1.path.count }
    }
}

extension Workspace {
    /// Asks the system to eject the volume; when it is gone, the tree hears of it (the app
    /// reloads the roots on every unmount). A failure becomes a notice naming the volume.
    func eject(_ path: String) -> Bool {
        guard let volume = ejectableVolume(containing: path), volume.path == path else {
            return false
        }
        system.eject(path) { [weak self] message in
            self?.addNotice("Eject “\(volume.title)”: \(message)")
            self?.notifyChange()
        }
        return false
    }
}
