import Foundation

/// Work a side does in the background that is not a file operation (#112 step 3): a search, or
/// measuring folder sizes. It runs where it always did — on its side, at once, never waiting in
/// the job queue — but is listed with the jobs, so the Jobs window shows how far it is and can
/// cancel it like any job.
public struct BackgroundTask: Identifiable, Equatable, Sendable {
    public let id: Int
    /// "Finding “*.jpg” in “Pictures”".
    public let title: String
    /// Which window, when there is more than one (as a job's origin).
    public let origin: String?
    public let started: Date
    /// "1,204 folders searched · 37 found".
    public internal(set) var progress = ""
}

/// The tasks of every window, in `AppModel`: what each is, whose it is, and how to cancel it.
struct BackgroundTasks {
    private struct Entry {
        var task: BackgroundTask
        weak var owner: Workspace?
        let cancel: @MainActor (Workspace) -> Void
    }

    private var entries: [Int: Entry] = [:]
    private var nextID = 1

    /// The tasks whose window is still open, oldest first.
    var all: [BackgroundTask] {
        entries.values.filter { $0.owner != nil }.map(\.task).sorted { $0.id < $1.id }
    }

    mutating func begin(_ title: String, origin: String?, owner: Workspace,
                        cancel: @escaping @MainActor (Workspace) -> Void) -> Int
    {
        let id = nextID
        nextID += 1
        entries[id] = Entry(task: BackgroundTask(id: id, title: title, origin: origin, started: Date()),
                            owner: owner, cancel: cancel)
        entries = entries.filter { $0.value.owner != nil } // a closed window's are gone
        return id
    }

    mutating func update(_ id: Int, _ progress: String) {
        entries[id]?.task.progress = progress
    }

    mutating func end(_ id: Int) {
        entries[id] = nil
    }

    /// The task's cancel, with its owner to run it on; nil if it is gone.
    func canceller(_ id: Int) -> (@MainActor (Workspace) -> Void, Workspace)? {
        guard let entry = entries[id], let owner = entry.owner else {
            return nil
        }
        return (entry.cancel, owner)
    }
}

public extension Workspace {
    /// Searches and folder measurings of every window, oldest first (#112).
    var backgroundTasks: [BackgroundTask] {
        app.tasks.all
    }
}

extension Workspace {
    func beginTask(_ title: String, cancel: @escaping @MainActor (Workspace) -> Void) -> Int {
        app.tasks.begin(title, origin: jobOrigin, owner: self, cancel: cancel)
    }

    func updateTask(_ id: Int?, _ progress: String) {
        if let id {
            app.tasks.update(id, progress)
        }
    }

    func endTask(_ id: Int?) {
        if let id {
            app.tasks.end(id)
        }
    }

    /// The window closes (#112): its searches and measurings stop — they belong to its sides —
    /// and every other window stops listing them at once.
    public func windowClosed() {
        for side in Side.allCases {
            findStops[side]?.set()
            findWork[side]?.cancel()
            findWork[side] = nil
            findStops[side] = nil
            endTask(findTasks.removeValue(forKey: side))
            stopMeasuring(side)
        }
        notifyChange()
    }

    /// Cancel in the Jobs window: the task's own stop, on its own window.
    func cancelTask(_ id: Int) -> Bool {
        guard let (cancel, owner) = app.tasks.canceller(id) else {
            return false
        }
        cancel(owner)
        app.tasks.end(id)
        return true
    }
}
