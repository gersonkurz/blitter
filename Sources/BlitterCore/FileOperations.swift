import Foundation

/// What a running operation can use: check cancellation, report progress, ask about conflicts.
/// Called on the job's own thread.
protocol OperationContext: AnyObject, Sendable {
    /// Set when the job is cancelled; also handed to folder listings, which stop between batches.
    var cancellation: CancellationFlag { get }
    func update(_ change: (inout JobProgress) -> Void)
    /// Blocks until the conflict is answered; nil if the job was cancelled meanwhile.
    func ask(_ conflict: Conflict) -> ConflictAnswer?
    /// The rest of the job runs to the end as one step (a batch rename, #54): false if it was
    /// cancelled already, otherwise Cancel has no effect from now on and the job finishes.
    func commit() -> Bool
}

extension OperationContext {
    func commit() -> Bool {
        !cancellation.isSet
    }
}

/// Carries out file operations synchronously on the calling (job) thread.
///
/// Safety rules: nothing is ever overwritten in place. A copy is written under a hidden temporary
/// name in the destination folder and renamed to its final name only when complete, with
/// `RENAME_EXCL`, so a cancelled or failed copy leaves nothing but the temporary item (which is
/// removed), and an existing item is never merged into. Replacing an existing item moves it to the
/// Trash first. Deleting means the Trash, except for `.delete`, which the user asks for explicitly.
struct FileOperations {
    /// Moves an item to the Trash and returns where it is there (nil if the system does not
    /// say), so Undo can put it back (#61). Tests use a folder of their own instead of the
    /// user's Trash.
    typealias Trasher = @Sendable (String) throws -> String?
    /// Removes an item for good (only ever a partial copy of our own, or the original after a
    /// complete move to another volume). Returns 0 or an errno; tests make it fail.
    typealias Remover = @Sendable (String) -> Int32
    /// Renames an item to a name that must be free (`RENAME_EXCL`). Returns 0 or an errno;
    /// tests make it fail at chosen steps of a batch rename.
    typealias Renamer = @Sendable (String, String) -> Int32

    let context: OperationContext
    let trashItem: Trasher
    let removeItem: Remover
    let renameItem: Renamer
    /// Tests watch (and cancel) size scans through this.
    let sizingProbe: (@Sendable (CancellationFlag) -> Void)?
    /// Tests set this to take the paths used between volumes (no clone, no rename) on one volume.
    let simulateOtherVolume: Bool

    private var errors: [JobError] = []
    /// How to undo what was done so far, in the order it was done (#61).
    var undoSteps: [UndoStep] = []
    /// Items moved to another volume are copies there: their old identities and the new ones.
    var identityChanges: [ItemIdentity: ItemIdentity] = [:]
    private var answerForAll: ConflictDecision?

    init(context: OperationContext, trash: @escaping Trasher = FileOperations.moveToTrash,
         remove: @escaping Remover = FileOperations.removeForGood, simulateOtherVolume: Bool = false,
         sizingProbe: (@Sendable (CancellationFlag) -> Void)? = nil,
         rename: @escaping Renamer = FileOperations.renameExclusive)
    {
        self.context = context
        trashItem = trash
        removeItem = remove
        renameItem = rename
        self.sizingProbe = sizingProbe
        self.simulateOtherVolume = simulateOtherVolume
    }

    var isCancelled: Bool {
        context.cancellation.isSet
    }

    @Sendable static func renameExclusive(_ path: String, _ target: String) -> Int32 {
        renamex_np(path, target, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
    }

    @Sendable static func removeForGood(_ path: String) -> Int32 {
        removefile(path, nil, removefile_flags_t(REMOVEFILE_RECURSIVE)) == 0 ? 0 : errno
    }

    @Sendable static func moveToTrash(_ path: String) throws -> String? {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &trashed)
        return trashed?.path
    }

    /// Runs the operation and returns the problems, one per item that could not be handled.
    mutating func run(_ operation: FileOperation) -> [JobError] {
        switch operation {
        case let .copy(sources, folder):
            transfer(sources, into: folder, move: false)
        case let .move(sources, folder):
            transfer(sources, into: folder, move: true)
        case let .trash(paths):
            trash(paths)
        case let .delete(paths):
            delete(paths)
        case let .command(arguments, folder):
            // Cancelled before it started: it never runs.
            // Its output goes to the job's progress as it comes, for a dialog to show (#43).
            let context = context
            let output = { (data: Data) in
                context.update { progress in
                    progress.outputBytes.append(data)
                    if progress.outputBytes.count > JobProgress.outputLimit {
                        progress.outputBytes = progress.outputBytes.suffix(JobProgress.outputLimit)
                    }
                }
            }
            if !isCancelled,
               let problem = Self.runCommand(arguments, in: folder, cancelled: context.cancellation, output: output)
            {
                fail(folder, problem)
            }
        case let .rename(path, name):
            rename(path, to: name)
        case let .renameAll(renames):
            renameAll(renames)
        case let .newFolder(folder, name):
            newFolder(in: folder, name: name)
        case let .undo(steps):
            runUndo(steps)
        }
        return errors
    }

    // MARK: Copy and move

    private mutating func transfer(_ sources: [String], into folder: String, move: Bool) {
        context.update { $0.totalItems = sources.count }
        if !move {
            let total = sources.reduce(Int64(0)) { $0 + measure($1) }
            context.update { $0.totalBytes = total }
        }
        for source in sources {
            guard !isCancelled else {
                return
            }
            let name = (source as NSString).lastPathComponent
            context.update { $0.currentItem = name }
            transferItem(source, into: folder, move: move)
            context.update { $0.doneItems += 1 }
        }
        context.update { $0.currentItem = nil }
    }

    private mutating func transferItem(_ source: String, into folder: String, move: Bool) {
        let name = (source as NSString).lastPathComponent
        let parent = (source as NSString).deletingLastPathComponent
        // Compared by file identity, not by path, so aliases and case differences cannot fool it.
        if Self.isSameOrAncestor(source, of: folder, resolvingLast: true) {
            fail(source, "A folder cannot be copied or moved into itself.")
            return
        }
        var target = (folder as NSString).appendingPathComponent(name)
        if Self.isSameFolder(parent, folder) {
            guard !move else {
                return // moving an item to where it already is
            }
            target = Self.freeName(for: name, in: folder) // copying in place duplicates it
        } else if Self.exists(target) {
            guard let decision = decide(Conflict(source: source, existing: target)) else {
                return // cancelled while asking
            }
            switch decision {
            case .skip:
                return
            case .keepBoth:
                target = Self.freeName(for: name, in: folder)
            case .replace:
                // Replacing the source itself, or a folder that contains it, would throw it away.
                guard !Self.isSameOrAncestor(target, of: source, resolvingLast: false) else {
                    fail(source, "“\(name)” cannot replace an item that contains it.")
                    return
                }
                do {
                    if let trashed = try trashItem(target) {
                        recordMove(trashed, back: target) // put back once the new one is gone
                    }
                } catch {
                    fail(target, "Could not move the existing item to the Trash: \(error.localizedDescription)")
                    return
                }
            }
        }
        if move {
            moveItem(source, to: target)
        } else if copyItem(source, to: target) {
            recordTrash(target)
        }
    }

    private mutating func decide(_ conflict: Conflict) -> ConflictDecision? {
        if let answerForAll {
            return answerForAll
        }
        guard let answer = context.ask(conflict) else {
            return nil
        }
        if answer.applyToAll {
            answerForAll = answer.decision
        }
        return answer.decision
    }

    /// Records how to undo it: back to `source`, or (copied to another volume, the original
    /// still there) the copy to the Trash.
    mutating func moveItem(_ source: String, to target: String) {
        if !simulateOtherVolume, renamex_np(source, target, UInt32(RENAME_EXCL)) == 0 {
            recordMove(target, back: source)
            return
        }
        let code = simulateOtherVolume ? EXDEV : errno
        guard code == EXDEV else {
            fail(source, Self.message(code))
            return
        }
        // Another volume: copy, and remove the original only if the copy is complete.
        // The copies will be other items (#61): what each original is, and below, each copy.
        guard let before = identities(below: source) else {
            return // cancelled before anything was copied
        }
        let size = measure(source)
        context.update { $0.totalBytes = ($0.totalBytes ?? 0) + size }
        guard copyItem(source, to: target) else {
            return
        }
        // Read before the original goes: once it is gone, the move counts, cancelled or not.
        guard let after = identities(below: target), !isCancelled else {
            recordTrash(target) // cancelled with the copy made: both stay, and the copy is the change
            return
        }
        let removed = removeItem(source)
        if removed != 0 {
            fail(source, "Copied, but the original could not be removed: \(Self.message(removed))")
            recordTrash(target)
        } else {
            recordReplaced(before, by: after)
            recordMove(target, back: source)
        }
    }

    /// Returns whether the copy is complete at `target`.
    @discardableResult
    private mutating func copyItem(_ source: String, to target: String) -> Bool {
        if !simulateOtherVolume, clonefile(source, target, UInt32(CLONE_NOFOLLOW)) == 0 {
            // A clone shares the data and needs no time: count it as copied in one go.
            let size = measure(target)
            context.update { $0.doneBytes += size }
            return true
        }
        let folder = (target as NSString).deletingLastPathComponent
        let temporary = (folder as NSString).appendingPathComponent(".blitter-partial-" + UUID().uuidString)
        let copied = DataCopy(context: context).copy(source, to: temporary)
        guard copied.complete, !isCancelled else {
            if let message = copied.error, !isCancelled {
                fail(source, message)
            }
            removePartialCopy(temporary)
            return false
        }
        let renamed = renameItem(temporary, target) // RENAME_EXCL; tests stop the job right here
        guard renamed == 0 else {
            fail(source, Self.message(renamed))
            removePartialCopy(temporary)
            return false
        }
        return true
    }

    /// A partial copy that cannot be removed is reported with its location, cancelled job or not.
    private mutating func removePartialCopy(_ path: String) {
        guard Self.exists(path) else {
            return
        }
        let code = removeItem(path)
        if code != 0 {
            fail(path, "An incomplete copy could not be removed: \(Self.message(code))")
        }
    }

    // MARK: Trash, rename, new folder

    private mutating func newFolder(in folder: String, name: String) {
        guard !isCancelled else {
            return
        }
        guard Self.isValidName(name) else {
            fail(folder, "“\(name)” is not a valid name.")
            return
        }
        let path = (folder as NSString).appendingPathComponent(name)
        if mkdir(path, 0o777) != 0 {
            fail(path, errno == EEXIST ? "An item named “\(name)” already exists." : Self.message(errno))
        } else {
            recordTrash(path)
        }
    }

    // MARK: Helpers

    /// Every size scan goes through here, so each one stops when the job is cancelled.
    private func measure(_ path: String) -> Int64 {
        Self.size(of: path, cancelled: context.cancellation, visit: sizingProbe)
    }

    mutating func fail(_ path: String, _ message: String) {
        errors.append(JobError(path: path, message: message))
    }
}
