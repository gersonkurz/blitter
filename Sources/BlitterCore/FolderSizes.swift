import Foundation

/// What a folder holds in bytes (#52).
public enum FolderSizes {
    /// The logical size of everything below `path`, added up: files and links (their own size),
    /// hidden items and the contents of packages included. Links are not followed and folders on
    /// another volume (a mount point below) are not entered, so nothing is counted twice and no
    /// network volume is walked by accident. Folders that cannot be read add nothing. Blocks the
    /// calling thread: call it on one of its own. Returns nil once `cancelled` is set, checked
    /// before every call that touches the disk. `visited` (tests) is called for each entry.
    public static func measure(_ path: String, cancelled: CancellationFlag) -> Int64? {
        measure(path, cancelled: cancelled, visited: {})
    }

    static func measure(_ path: String, cancelled: CancellationFlag, visited: () -> Void) -> Int64? {
        var info = stat()
        guard !cancelled.isSet else {
            return nil
        }
        guard stat(path, &info) == 0 else { // the folder chosen may be a link the user opened
            return cancelled.isSet ? nil : 0
        }
        let device = info.st_dev
        var bytes: Int64 = 0
        var folders = [path]
        while let folder = folders.popLast() {
            guard !cancelled.isSet else {
                return nil
            }
            guard let entries = try? listDirectory(folder, cancelled: cancelled) else {
                continue
            }
            for entry in entries {
                guard !cancelled.isSet else {
                    return nil // not one more lstat after Stop (#52 review)
                }
                visited()
                guard entry.kind == .directory else {
                    bytes += entry.size
                    continue
                }
                let child = folder == "/" ? "/" + entry.name : folder + "/" + entry.name
                if lstat(child, &info) == 0, info.st_dev == device {
                    folders.append(child)
                }
            }
        }
        return cancelled.isSet ? nil : bytes
    }
}
