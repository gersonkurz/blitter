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

/// Watches a set of folders, each with its own FSEvents stream, and reports which of them changed.
///
/// - FSEvents keeps no file descriptor open, so a watched volume can still be ejected.
/// - Events are coalesced for `latency` seconds, and the chunks FSEvents hands one burst out in
///   are merged, so unpacking an archive arrives as one report.
/// - One stream per folder, each made on a background thread (#29): making a stream opens its
///   folder, and that `open` can wait for a privacy prompt (Documents, Desktop) or a stalled
///   network volume — at first or on any later visit. Only that folder waits; the others keep
///   their streams, which a change of the watched set never touches.
/// - Nothing is lost while a folder waits: its stream starts at the newest event the watcher had
///   seen when the folder was asked for (or when the watcher was made), so FSEvents replays what
///   happened since. Create the watcher before reading the folders it will watch.
/// - A folder that cannot be opened (not there yet, access refused) is not watched; the next
///   `watch`, even with the same set, tries it again.
/// - FSEvents reports resolved paths (`/private/tmp` for `/tmp`); they are mapped back to the
///   paths given to `watch`.
///
/// Stream handling runs on the watcher's own queue; `onChange` is called there.
public final class FolderWatcher: FolderWatching, @unchecked Sendable {
    /// The path to give FSEvents for a folder, or nil if the folder cannot be opened now. Runs on
    /// a background thread.
    public typealias Resolver = @Sendable (String) -> String?

    private let queue = DispatchQueue(label: "Blitter.FolderWatcher")
    private static let queueKey = DispatchSpecificKey<Void>()
    private let latency: Double
    private let resolve: Resolver
    private let onChange: @Sendable ([FolderChange]) -> Void
    /// Only touched on `queue`.
    private var watched: Set<String> = []
    /// Watched path → its running stream.
    private var streams: [String: StreamHandle] = [:]
    /// Folders whose stream is being made on a background thread. One at a time per folder: a
    /// folder asked for again while its stream is still being made waits for that one, so a
    /// folder that hangs never ties up more than one thread, however often it is revisited.
    private var inFlight: Set<String> = []
    /// The newest event seen by any stream; a folder asked for now starts there.
    private var lastEventID: FSEventStreamEventId
    /// Identifies each stream, so events of one that has been replaced are ignored.
    private var nextAttempt = 0
    /// Changes collected from the callbacks of one burst, by watched path.
    private var pending: [String: Bool] = [:]

    public init(latency: Double = 0.3, resolve: @escaping Resolver = { FolderWatcher.watchablePath($0) },
                onChange: @escaping @Sendable ([FolderChange]) -> Void)
    {
        self.latency = latency
        self.resolve = resolve
        self.onChange = onChange
        lastEventID = FSEventsGetCurrentEventId()
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    deinit {
        // A running stream reaches the watcher only weakly, but it must not outlive it. Queued
        // work holds the watcher weakly too; the last reference can still be dropped on the queue
        // itself, where a sync would deadlock. Streams still being made release themselves when
        // they find the watcher gone.
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            stopAll()
        } else {
            queue.sync { stopAll() }
        }
    }

    /// Replaces the watched folders: new ones get a stream, dropped ones lose theirs, the rest
    /// keep theirs untouched. Folders that could not be opened before are tried again.
    public func watch(_ paths: Set<String>) {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            for path in watched.subtracting(paths) {
                stop(path)
            }
            watched = paths
            for path in paths where streams[path] == nil && !inFlight.contains(path) {
                startStream(for: path)
            }
        }
    }

    /// The real path of a folder that opens now, as FSEvents' root watching opens it.
    public static func watchablePath(_ path: String) -> String? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            return nil
        }
        close(descriptor)
        return realPath(path)
    }

    public static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else {
            return path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: Streams

    /// A running stream and what its callback knows; handed between threads, used on one at a
    /// time.
    private struct StreamHandle: @unchecked Sendable {
        let stream: FSEventStreamRef
        let info: Unmanaged<StreamInfo>
        let streamPath: String
        let attempt: Int

        func release(started: Bool) {
            if started {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
            }
            FSEventStreamRelease(stream)
            info.release()
        }
    }

    /// What a stream's callback needs: whose stream it is. It reaches the watcher only weakly, so
    /// neither a stream nor a thread still making one keeps the watcher alive.
    private final class StreamInfo: @unchecked Sendable {
        weak var watcher: FolderWatcher?
        let path: String
        let attempt: Int

        init(watcher: FolderWatcher, path: String, attempt: Int) {
            self.watcher = watcher
            self.path = path
            self.attempt = attempt
        }
    }

    /// Makes the folder's stream on a background thread, then starts it on the queue if the
    /// folder is still watched. The thread holds only `StreamInfo`, never the watcher.
    private func startStream(for path: String) {
        nextAttempt += 1
        let attempt = nextAttempt
        inFlight.insert(path)
        let info = StreamInfo(watcher: self, path: path, attempt: attempt)
        let since = lastEventID
        let (resolve, latency, queue) = (resolve, latency, queue)
        DispatchQueue.global(qos: .utility).async {
            var handle: StreamHandle?
            // Both steps can wait for a privacy prompt or a stalled volume: here they only hold up
            // this folder.
            if let streamPath = resolve(path) {
                let retained = Unmanaged.passRetained(info)
                var context = FSEventStreamContext(version: 0, info: retained.toOpaque(), retain: nil, release: nil,
                                                   copyDescription: nil)
                let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagWatchRoot)
                if let stream = FSEventStreamCreate(nil, Self.callback, &context, [streamPath] as CFArray, since,
                                                    latency, flags)
                {
                    handle = StreamHandle(stream: stream, info: retained, streamPath: streamPath, attempt: attempt)
                } else {
                    retained.release()
                }
            }
            queue.async {
                guard let watcher = info.watcher else {
                    handle?.release(started: false) // the watcher is gone
                    return
                }
                watcher.streamMade(handle, for: path)
            }
        }
    }

    /// The stream is made (nil: the folder could not be opened; the next `watch` tries again).
    private func streamMade(_ handle: StreamHandle?, for path: String) {
        inFlight.remove(path)
        guard let handle else {
            return
        }
        guard watched.contains(path), streams[path] == nil else {
            handle.release(started: false) // dropped while it was being made
            return
        }
        FSEventStreamSetDispatchQueue(handle.stream, queue)
        FSEventStreamStart(handle.stream)
        streams[path] = handle
    }

    private func stop(_ path: String) {
        streams.removeValue(forKey: path)?.release(started: true)
    }

    private func stopAll() {
        for path in Array(streams.keys) {
            stop(path)
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
        guard let info else {
            return
        }
        let streamInfo = Unmanaged<StreamInfo>.fromOpaque(info).takeUnretainedValue()
        let eventPaths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        let eventFlags = UnsafeBufferPointer(start: flags, count: count)
        let eventIDs = UnsafeBufferPointer(start: ids, count: count)
        streamInfo.watcher?.handle(Array(zip(eventPaths, eventFlags)), newestID: eventIDs.max(),
                                   for: streamInfo.path, attempt: streamInfo.attempt)
    }

    /// Without file-level events, FSEvents reports the folder whose contents changed. Changes in
    /// its subfolders (which may have streams of their own) are not this folder's.
    private func handle(_ events: [(path: String, flags: FSEventStreamEventFlags)], newestID: FSEventStreamEventId?,
                        for path: String, attempt: Int)
    {
        guard let stream = streams[path], stream.attempt == attempt else {
            return
        }
        let streamPath = stream.streamPath
        if let newestID {
            lastEventID = max(lastEventID, newestID)
        }
        let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagRootChanged)
        let historyDone = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
        var changed = false
        var rescan = false
        // A stream started from an earlier event ends its replay with a marker that carries its
        // path; it is not a change.
        for (eventPath, flags) in events where flags & historyDone == 0 {
            let trimmed = eventPath.count > 1 && eventPath.hasSuffix("/") ? String(eventPath.dropLast()) : eventPath
            let isRescan = flags & rescanFlags != 0
            if trimmed == streamPath || (isRescan && (trimmed == "/" || streamPath.hasPrefix(trimmed + "/"))) {
                changed = true
                rescan = rescan || isRescan
            }
        }
        if changed {
            report([path: rescan])
        }
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
