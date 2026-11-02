import BlitterCore
import Foundation
import UniformTypeIdentifiers

/// A search shown on a side (#48): what was searched for, below which folder, and how far it got.
/// The side's `location` stays that folder; each result is listed under its path relative to it.
public struct FindState: Equatable, Sendable {
    /// The folder searched below: the side's `location` and `entriesLocation`.
    public let root: String
    public let pattern: String
    public internal(set) var isRunning = true
    /// Folders read so far, and folders that could not be read (skipped).
    public internal(set) var foldersSearched = 0
    public internal(set) var unreadableFolders = 0

    /// What the path field shows for it.
    public var displayLocation: String {
        Self.scheme + root + "?name=" + pattern
    }

    /// Shown, never parsed: a folder or pattern may contain anything, "?name=" included.
    static let scheme = "search://"
}

/// Some results of a walk, and how far it got.
struct FindBatch: Sendable {
    var entries: [DirectoryEntry] = []
    var foldersSearched = 0
    var unreadableFolders = 0
}

/// Walking a folder tree for names (#48). Everything here reads the disk: it runs on a thread of
/// its own, never on the main thread or the Swift concurrency pool (a slow volume blocks only it).
enum FileFind {
    /// Walks below `root`, breadth first (results near the top come first), and hands over the
    /// matching entries in batches, at most every `interval` seconds. Each result's name is its path relative
    /// to `root`, and it counts as hidden when anything on that path is. Not entered: symbolic
    /// links (no loops), packages (an app is one item), folders on another volume (like
    /// `find -xdev`: a network volume mounted below is never searched by accident), and hidden
    /// folders unless `includeHidden`. Stops between folders once `cancelled` is set, and always
    /// ends with a batch holding the final counts.
    static func walk(root: String, matcher: QuickFilter.Matcher, includeHidden: Bool, cancelled: CancellationFlag,
                     interval: TimeInterval = 0.2, emit: (FindBatch) -> Void)
    {
        var types = ContentTypes()
        let rootDevice = device(of: root, following: true) // where the folder chosen really is
        var queue = [Folder(path: root, relative: "", hidden: false)]
        var next = 0
        var batch = FindBatch()
        var lastEmit = Date()
        while next < queue.count, !cancelled.isSet {
            let folder = queue[next]
            next += 1
            guard let entries = try? listDirectory(folder.path, cancelled: cancelled) else {
                batch.unreadableFolders += cancelled.isSet ? 0 : 1
                continue
            }
            batch.foldersSearched += 1
            for entry in entries where includeHidden || !entry.isHidden {
                let relative = folder.relative.isEmpty ? entry.name : folder.relative + "/" + entry.name
                let hidden = folder.hidden || entry.isHidden
                if matcher.matches(entry.name) {
                    var found = entry
                    found.name = relative
                    found.isHidden = hidden
                    batch.entries.append(found)
                }
                guard entry.kind == .directory, !types.classify(entry).type.conforms(to: .package) else {
                    continue
                }
                let path = Paths.appending(entry.name, to: folder.path)
                if device(of: path, following: false) == rootDevice {
                    queue.append(Folder(path: path, relative: relative, hidden: hidden))
                }
            }
            if Date().timeIntervalSince(lastEmit) >= interval {
                emit(batch)
                batch.entries = []
                lastEmit = Date()
            }
            if next > 4096 { // the queue keeps only what is still to come
                queue.removeFirst(next)
                next = 0
            }
        }
        emit(batch)
    }

    /// A folder still to read: where it is, its path below the root, and whether it is hidden
    /// (or inside a hidden one).
    private struct Folder {
        let path: String
        let relative: String
        let hidden: Bool
    }

    /// `following`: the root may be a link the user opened (to another volume, say), and is
    /// searched where it leads; below it, links are never entered anyway.
    private static func device(of path: String, following: Bool) -> dev_t? {
        var info = stat()
        return (following ? stat(path, &info) : lstat(path, &info)) == 0 ? info.st_dev : nil
    }
}
