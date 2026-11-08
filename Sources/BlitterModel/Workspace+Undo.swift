import BlitterCore

/// A job that can be undone (#61): what it did, and the steps that undo it.
public struct UndoEntry: Equatable, Sendable {
    public let id: Int
    /// What was done, as Undo names it: "Undo Move to Trash".
    public let title: String
    let steps: [UndoStep]

    /// What Undo changes, for the automation socket's preview: the items it takes to the Trash
    /// or renames, and the places it puts items back to.
    public var items: [String] {
        steps.flatMap { step -> [String] in
            switch step {
            case let .trash(path, _): [path]
            case let .move(_, target, _): [target]
            case let .rename(renames, _): renames.map(\.path)
            }
        }
    }

    static func title(of operation: FileOperation) -> String? {
        switch operation {
        case .copy: "Copy"
        case .move: "Move"
        case .trash: "Move to Trash"
        case .rename, .renameAll: "Rename"
        case .newFolder: "New Folder"
        case .delete, .command, .undo: nil // gone for good, unknown, or an undo itself
        }
    }
}

// MARK: The undo journal (#61)

/// Every job that changed files records how to undo it; Undo takes back the last one, as a job
/// of its own. Whatever started the job (a menu, a drop, the automation socket) and whatever
/// undoes it, it is the same journal. It lasts while Blitter runs. Undo puts items back only
/// where nothing is now: what changed since is reported, not overwritten.
public extension Workspace {
    /// The last job that can be undone.
    var lastUndo: UndoEntry? {
        undoJournal.last
    }

    /// Whether Undo can run now: there is something to undo, and no undo is running. Undos run
    /// one at a time, so each finds what the one before put back.
    var canUndo: Bool {
        lastUndo != nil && runningUndo == nil
    }

    /// Entries kept; older ones are forgotten.
    internal static let undoLimit = 100

    /// A finished job's steps join the journal, cancelled or with problems too: they are what was
    /// done. An undo job adds nothing (there is no redo).
    internal func recordUndo(of job: Job) {
        if job.id == runningUndo {
            runningUndo = nil
        }
        if !job.identityChanges.isEmpty { // items moved to another volume: the entries follow them
            undoJournal = undoJournal.map { entry in
                UndoEntry(
                    id: entry.id,
                    title: entry.title,
                    steps: entry.steps.map { $0.replacing(job.identityChanges) }
                )
            }
        }
        guard !job.undo.isEmpty, let title = UndoEntry.title(of: job.operation) else {
            return
        }
        nextUndoID += 1
        undoJournal.append(UndoEntry(id: nextUndoID, title: title, steps: job.undo))
        if undoJournal.count > Self.undoLimit {
            undoJournal.removeFirst(undoJournal.count - Self.undoLimit)
        }
    }

    /// Undoes the last entry if it is still `id` (what was shown or allowed is what is undone).
    internal func undo(_ id: Int) -> Bool {
        guard canUndo, let entry = undoJournal.last, entry.id == id else {
            return false
        }
        undoJournal.removeLast()
        runningUndo = startJob(.undo(entry.steps))
        return true
    }
}
