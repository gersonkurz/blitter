import BlitterCore
import Foundation
import UniformTypeIdentifiers

/// A search shown on a side (#48): what was searched for, below which folder, and how far it got.
/// The side's `location` stays that folder; each result is listed under its path relative to it.
public struct FindState: Equatable, Sendable {
    /// The folder searched below: the side's `location` and `entriesLocation`.
    public let root: String
    public let pattern: String
    /// Text the found files contain (#49); empty: names only.
    public var contents = ""
    public internal(set) var isRunning = true
    /// Folders read so far, and folders that could not be read (skipped).
    public internal(set) var foldersSearched = 0
    public internal(set) var unreadableFolders = 0
    /// Files whose contents were read (#49).
    public internal(set) var filesRead = 0

    /// What the path field shows for it.
    public var displayLocation: String {
        Self.scheme + root + "?name=" + pattern + (contents.isEmpty ? "" : "&contains=" + contents)
    }

    /// Shown, never parsed: a folder or pattern may contain anything, "?name=" included.
    static let scheme = "search://"
}

/// Some results of a walk, and how far it got.
struct FindBatch: Sendable {
    var entries: [DirectoryEntry] = []
    var foldersSearched = 0
    var unreadableFolders = 0
    var filesRead = 0
}

/// Walking a folder tree for names (#48). Everything here reads the disk: it runs on a thread of
/// its own, never on the main thread or the Swift concurrency pool (a slow volume blocks only it).
enum FileFind {
    /// Walks below `root`, breadth first (results near the top come first), and hands over the
    /// matching entries in batches, at most every `interval` seconds. Each result's name is its path relative
    /// to `root`, and it counts as hidden when anything on that path is. Not entered: symbolic
    /// links (no loops), packages (an app is one item), folders on another volume (like
    /// `find -xdev`: a network volume mounted below is never searched by accident), and hidden
    /// folders unless `includeHidden`. With `contents` (#49), only files whose name matches and
    /// that contain it are found: never a folder or link, never a cloud placeholder (reading it
    /// would download it). Stops between folders, between files and between the chunks of a file once
    /// `cancelled` is set, and always ends with a batch holding the final counts.
    static func walk(root: String, matcher: QuickFilter.Matcher, contents: String = "", includeHidden: Bool,
                     cancelled: CancellationFlag, interval: TimeInterval = 0.2, emit: @escaping (FindBatch) -> Void)
    {
        var walker = Walker(matcher: matcher, contents: contents, includeHidden: includeHidden, cancelled: cancelled,
                            interval: interval, emit: emit)
        walker.run(root)
    }

    /// One walk's state: the folders still to read, the batch being filled and when the last
    /// one went out.
    private struct Walker {
        let matcher: QuickFilter.Matcher
        let contents: String
        let includeHidden: Bool
        let cancelled: CancellationFlag
        let interval: TimeInterval
        let emit: (FindBatch) -> Void
        var types = ContentTypes()
        var rootDevice: dev_t?
        var queue: [Folder] = []
        var batch = FindBatch()
        var lastEmit = Date()

        init(matcher: QuickFilter.Matcher, contents: String, includeHidden: Bool, cancelled: CancellationFlag,
             interval: TimeInterval, emit: @escaping (FindBatch) -> Void)
        {
            self.matcher = matcher
            self.contents = contents
            self.includeHidden = includeHidden
            self.cancelled = cancelled
            self.interval = interval
            self.emit = emit
        }

        mutating func run(_ root: String) {
            rootDevice = device(of: root, following: true) // where the folder chosen really is
            queue = [Folder(path: root, relative: "", hidden: false)]
            var next = 0
            while next < queue.count, !cancelled.isSet {
                let folder = queue[next]
                next += 1
                read(folder)
                emitIfDue()
                if next > 4096 { // the queue keeps only what is still to come
                    queue.removeFirst(next)
                    next = 0
                }
            }
            emit(batch)
        }

        private mutating func read(_ folder: Folder) {
            guard let entries = try? listDirectory(folder.path, cancelled: cancelled) else {
                batch.unreadableFolders += cancelled.isSet ? 0 : 1
                return
            }
            batch.foldersSearched += 1
            for entry in entries where includeHidden || !entry.isHidden {
                if cancelled.isSet {
                    return // not one more file opened after Stop (#49 review)
                }
                consider(entry, in: folder)
            }
        }

        /// A result if it matches; a folder to read later if it is one to enter.
        private mutating func consider(_ entry: DirectoryEntry, in folder: Folder) {
            let relative = folder.relative.isEmpty ? entry.name : folder.relative + "/" + entry.name
            let hidden = folder.hidden || entry.isHidden
            if matcher.matches(entry.name), contents.isEmpty || holdsContents(entry, in: folder.path) {
                var found = entry
                found.name = relative
                found.isHidden = hidden
                batch.entries.append(found)
            }
            if !contents.isEmpty {
                emitIfDue() // reading files can make one folder take long (#49 review)
            }
            guard entry.kind == .directory, !types.classify(entry).type.conforms(to: .package) else {
                return
            }
            let path = Paths.appending(entry.name, to: folder.path)
            if device(of: path, following: false) == rootDevice {
                queue.append(Folder(path: path, relative: relative, hidden: hidden))
            }
        }

        /// Whether a found file holds the text: only a file with its contents on this Mac is read.
        private mutating func holdsContents(_ entry: DirectoryEntry, in folder: String) -> Bool {
            guard entry.kind == .file, !entry.isDataless else {
                return false
            }
            batch.filesRead += 1
            return ContentSearch.file(Paths.appending(entry.name, to: folder), contains: contents, cancelled: cancelled)
        }

        /// Hands over what was found so far once `interval` has passed.
        private mutating func emitIfDue() {
            if Date().timeIntervalSince(lastEmit) >= interval {
                emit(batch)
                batch.entries = []
                lastEmit = Date()
            }
        }
    }

    /// The walk on a GCD thread of its own (a slow volume blocks only it), its batches as they come.
    static func batches(root: String, matcher: QuickFilter.Matcher, contents: String, includeHidden: Bool,
                        cancelled: CancellationFlag) -> AsyncStream<FindBatch>
    {
        AsyncStream { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                walk(root: root, matcher: matcher, contents: contents, includeHidden: includeHidden,
                     cancelled: cancelled) { continuation.yield($0) }
                continuation.finish()
            }
        }
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
