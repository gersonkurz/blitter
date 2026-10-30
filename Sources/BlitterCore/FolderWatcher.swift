import CoreServices
import Foundation

/// A folder whose contents changed on disk.
public struct FolderChange: Equatable, Sendable {
    /// The watched path as it was given to `watch`, not the resolved one FSEvents reports.
    public let path: String
    /// FSEvents dropped details (or the folder itself was moved or deleted): everything at and
    /// below `path` may have changed.
    public let includesSubfolders: Bool

    public init(path: String, includesSubfolders: Bool) {
        self.path = path
        self.includesSubfolders = includesSubfolders
    }
}

/// Something that watches folders; the workspace replaces the set whenever what is visible changes.
public protocol FolderWatching: AnyObject, Sendable {
    func watch(_ paths: Set<String>)
}

/// Watches a set of folders with one FSEvents stream and reports which of them changed.
///
/// - FSEvents keeps no file descriptor open, so a watched volume can still be ejected.
/// - Events are coalesced for `latency` seconds, and the chunks FSEvents hands one burst out in
///   are merged, so unpacking an archive arrives as one report.
/// - Nothing is lost across a change of the watched set: every new stream starts at the last
///   event the previous one saw, and the first one at the moment the watcher was created, so
///   FSEvents replays whatever happened in between. Create the watcher before reading the
///   folders it will watch.
/// - FSEvents reports resolved paths (`/private/tmp` for `/tmp`); they are mapped back to the
///   paths given to `watch`. Resolving can block on a stalled network volume, so each path is
///   resolved on its own background task; until then it is watched as given.
///
/// Stream handling runs on the watcher's own queue; `onChange` is called there.
public final class FolderWatcher: FolderWatching, @unchecked Sendable {
    public typealias Resolver = @Sendable (String) -> String

    private let queue = DispatchQueue(label: "Blitter.FolderWatcher")
    private static let queueKey = DispatchSpecificKey<Void>()
    private let latency: Double
    private let resolve: Resolver
    private let onChange: @Sendable ([FolderChange]) -> Void
    // Only touched on `queue`.
    private var stream: FSEventStreamRef?
    private var watched: Set<String> = []
    /// The newest event seen; the next stream starts there.
    private var lastEventID: FSEventStreamEventId
    /// Watched path → its resolved path, once known.
    private var resolved: [String: String] = [:]
    private var resolving: Set<String> = []
    /// Resolved path → the watched paths that resolve to it, for the running stream.
    private var byStreamPath: [String: [String]] = [:]
    /// Changes collected from the callbacks of one burst, by watched path.
    private var pending: [String: Bool] = [:]

    public init(latency: Double = 0.3, resolve: @escaping Resolver = { FolderWatcher.realPath($0) },
                onChange: @escaping @Sendable ([FolderChange]) -> Void)
    {
        self.latency = latency
        self.resolve = resolve
        self.onChange = onChange
        lastEventID = FSEventsGetCurrentEventId()
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    deinit {
        // The stream refers to the watcher without retaining it, so it must be gone before the
        // watcher is. Queued work holds the watcher weakly, but the last reference can still be
        // dropped on the queue itself, where a sync would deadlock.
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            stopStream()
        } else {
            queue.sync { stopStream() }
        }
    }

    /// Replaces the watched folders. Does nothing if the set is unchanged.
    public func watch(_ paths: Set<String>) {
        queue.async { [weak self] in
            guard let self, paths != watched else {
                return
            }
            watched = paths
            resolveNewPaths()
            restart()
        }
    }

    // MARK: Paths

    private func resolveNewPaths() {
        for path in watched where resolved[path] == nil && !resolving.contains(path) {
            resolving.insert(path)
            let resolve = resolve
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result = resolve(path)
                self?.queue.async { [weak self] in self?.resolvedPath(path, result) }
            }
        }
    }

    private func resolvedPath(_ path: String, _ result: String) {
        resolving.remove(path)
        resolved[path] = result
        // Only a path that resolves differently changes what the stream must watch. Until now its
        // events arrived under the resolved path and matched nothing, so a change may have been
        // missed: report it as changed once, and the folder is read again.
        guard result != path, watched.contains(path) else {
            return
        }
        restart()
        report([path: false])
    }

    public static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else {
            return path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: Stream

    private func restart() {
        var byStreamPath: [String: [String]] = [:]
        for path in watched {
            byStreamPath[resolved[path] ?? path, default: []].append(path)
        }
        guard byStreamPath != self.byStreamPath || stream == nil else {
            return
        }
        stopStream()
        self.byStreamPath = byStreamPath
        guard !byStreamPath.isEmpty else {
            return
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, Self.callback, &context, Array(byStreamPath.keys) as CFArray,
                                               lastEventID, latency, flags)
        else {
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stopStream() {
        guard let stream else {
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
        guard let info else {
            return
        }
        let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
        let eventPaths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        let eventFlags = UnsafeBufferPointer(start: flags, count: count)
        let eventIDs = UnsafeBufferPointer(start: ids, count: count)
        watcher.handle(Array(zip(eventPaths, eventFlags)), newestID: eventIDs.max())
    }

    /// Without file-level events, FSEvents reports the folder whose contents changed. Changes in
    /// folders nobody watches (subfolders of a watched folder) are ignored.
    private func handle(_ events: [(path: String, flags: FSEventStreamEventFlags)], newestID: FSEventStreamEventId?) {
        if let newestID {
            lastEventID = max(lastEventID, newestID)
        }
        var changes: [String: Bool] = [:]
        let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagRootChanged)
        for (path, flags) in events {
            let eventPath = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            let rescan = flags & rescanFlags != 0
            for (streamPath, originals) in byStreamPath {
                let matches = streamPath == eventPath
                    || (rescan && (eventPath == "/" || streamPath.hasPrefix(eventPath + "/")))
                guard matches else {
                    continue
                }
                for original in originals {
                    changes[original] = (changes[original] ?? false) || rescan
                }
            }
        }
        report(changes)
    }

    /// Collects changes for the next flush.
    private func report(_ changes: [String: Bool]) {
        guard !changes.isEmpty else {
            return
        }
        let flushIsScheduled = !pending.isEmpty
        pending.merge(changes) { $0 || $1 }
        if !flushIsScheduled {
            // FSEvents delivers the chunks of one burst back to back; collect them all first.
            queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.flush() }
        }
    }

    private func flush() {
        // Folders that stopped being watched since the change came in are not reported.
        let changes = pending.filter { watched.contains($0.key) }
        pending = [:]
        guard !changes.isEmpty else {
            return
        }
        onChange(changes.map { FolderChange(path: $0.key, includesSubfolders: $0.value) }
            .sorted { $0.path < $1.path })
    }
}
