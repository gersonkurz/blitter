import Foundation

/// What a running operation can use: check cancellation, report progress, ask about conflicts.
/// Called on the job's own thread.
protocol OperationContext: AnyObject, Sendable {
    /// Set when the job is cancelled; also handed to folder listings, which stop between batches.
    var cancellation: CancellationFlag { get }
    func update(_ change: (inout JobProgress) -> Void)
    /// Blocks until the conflict is answered; nil if the job was cancelled meanwhile.
    func ask(_ conflict: Conflict) -> ConflictAnswer?
}

/// Carries out file operations synchronously on the calling (job) thread.
///
/// Safety rules: nothing is ever overwritten in place. A copy is written under a hidden temporary
/// name in the destination folder and renamed to its final name only when complete, with
/// `RENAME_EXCL`, so a cancelled or failed copy leaves nothing but the temporary item (which is
/// removed), and an existing item is never merged into. Replacing an existing item moves it to the
/// Trash first. Deleting always means the Trash.
struct FileOperations {
    /// Moves an item to the Trash. Tests use a folder of their own instead of the user's Trash.
    typealias Trasher = @Sendable (String) throws -> Void
    /// Removes an item for good (only ever a partial copy of our own, or the original after a
    /// complete move to another volume). Returns 0 or an errno; tests make it fail.
    typealias Remover = @Sendable (String) -> Int32

    let context: OperationContext
    let trashItem: Trasher
    let removeItem: Remover
    /// Tests watch (and cancel) size scans through this.
    let sizingProbe: (@Sendable (CancellationFlag) -> Void)?
    /// Tests set this to take the paths used between volumes (no clone, no rename) on one volume.
    let simulateOtherVolume: Bool

    private var errors: [JobError] = []
    private var answerForAll: ConflictDecision?

    init(context: OperationContext, trash: @escaping Trasher = FileOperations.moveToTrash,
         remove: @escaping Remover = FileOperations.removeForGood, simulateOtherVolume: Bool = false,
         sizingProbe: (@Sendable (CancellationFlag) -> Void)? = nil)
    {
        self.context = context
        trashItem = trash
        removeItem = remove
        self.sizingProbe = sizingProbe
        self.simulateOtherVolume = simulateOtherVolume
    }

    private var isCancelled: Bool {
        context.cancellation.isSet
    }

    @Sendable static func removeForGood(_ path: String) -> Int32 {
        removefile(path, nil, removefile_flags_t(REMOVEFILE_RECURSIVE)) == 0 ? 0 : errno
    }

    @Sendable static func moveToTrash(_ path: String) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
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
        case let .rename(path, name):
            rename(path, to: name)
        case let .newFolder(folder, name):
            newFolder(in: folder, name: name)
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
                    try trashItem(target)
                } catch {
                    fail(target, "Could not move the existing item to the Trash: \(error.localizedDescription)")
                    return
                }
            }
        }
        if move {
            moveItem(source, to: target)
        } else {
            copyItem(source, to: target)
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

    private mutating func moveItem(_ source: String, to target: String) {
        if !simulateOtherVolume, renamex_np(source, target, UInt32(RENAME_EXCL)) == 0 {
            return
        }
        let code = simulateOtherVolume ? EXDEV : errno
        guard code == EXDEV else {
            fail(source, Self.message(code))
            return
        }
        // Another volume: copy, and remove the original only if the copy is complete.
        let size = measure(source)
        context.update { $0.totalBytes = ($0.totalBytes ?? 0) + size }
        guard copyItem(source, to: target), !isCancelled else {
            return
        }
        let removed = removeItem(source)
        if removed != 0 {
            fail(source, "Copied, but the original could not be removed: \(Self.message(removed))")
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
        guard renamex_np(temporary, target, UInt32(RENAME_EXCL)) == 0 else {
            fail(source, Self.message(errno))
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

    private mutating func trash(_ paths: [String]) {
        context.update { $0.totalItems = paths.count }
        for path in paths {
            guard !isCancelled else {
                return
            }
            context.update { $0.currentItem = (path as NSString).lastPathComponent }
            do {
                try trashItem(path)
            } catch {
                fail(path, error.localizedDescription)
            }
            context.update { $0.doneItems += 1 }
        }
    }

    private mutating func rename(_ path: String, to name: String) {
        guard !isCancelled else {
            return
        }
        guard Self.isValidName(name) else {
            fail(path, "“\(name)” is not a valid name.")
            return
        }
        let target = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
        // On a case-insensitive volume a change of case only names the same item: that is the one
        // case where the new name may already "exist". Anything else must not be overwritten.
        let isSameItem = Self.identity(target) != nil && Self.identity(target) == Self.identity(path)
        let flags = isSameItem ? 0 : UInt32(RENAME_EXCL)
        if renamex_np(path, target, flags) != 0 {
            fail(path, errno == EEXIST ? "An item named “\(name)” already exists." : Self.message(errno))
        }
    }

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
        }
    }

    // MARK: Helpers

    /// Every size scan goes through here, so each one stops when the job is cancelled.
    private func measure(_ path: String) -> Int64 {
        Self.size(of: path, cancelled: context.cancellation, visit: sizingProbe)
    }

    private mutating func fail(_ path: String, _ message: String) {
        errors.append(JobError(path: path, message: message))
    }
}
