import BlitterCore

/// File operations as commands. They run as jobs; when a job is done, the folders it changed are
/// read again right away (live updates would catch it too, but later, and not on every volume).
extension Workspace {
    /// The file operations in the background, newest last.
    public var jobs: [Job] {
        jobQueue.jobs
    }

    // MARK: Commands

    func transferSelection(move: Bool) -> Bool {
        let source = activeSide
        guard let state = sides[source], let destination = sides[source.opposite], !state.selection.isEmpty else {
            return false
        }
        let paths = selectedPaths(state)
        startJob(move ? .move(paths, into: destination.location) : .copy(paths, into: destination.location))
        return true
    }

    func runCommand(_ arguments: [String], in folder: String) -> Bool {
        guard !arguments.isEmpty else {
            return false
        }
        startJob(.command(arguments, folder: folder))
        return true
    }

    func transfer(_ paths: [String], into folder: String, move: Bool) -> Bool {
        guard !paths.isEmpty else {
            return false
        }
        startJob(move ? .move(paths, into: folder) : .copy(paths, into: folder))
        return true
    }

    /// Hands the side's selection to a system service. Changes no state.
    func withSelection(_ side: Side, _ service: ([SelectedItem]) -> Void) -> Bool {
        let items = selectedItems(on: side)
        if !items.isEmpty {
            service(items)
        }
        return false
    }

    func copyFolderPath(_ side: Side) -> Bool {
        if let folder = sides[side]?.entriesLocation {
            system.copyText(folder)
        }
        return false
    }

    func togglePreview(_ side: Side) -> Bool {
        system.togglePreview(side)
        return false
    }

    /// The side's selected entries in list order, with what the listing knows about them, so
    /// nobody has to ask the disk (e.g. for a pasteboard URL's folder flag).
    public func selectedItems(on side: Side) -> [SelectedItem] {
        guard let state = sides[side] else {
            return []
        }
        return state.selectedEntries.map {
            SelectedItem(path: Paths.appending($0.entry.name, to: state.entriesLocation),
                         isDirectory: $0.entry.kind == .directory)
        }
    }

    func trashSelection(_ side: Side) -> Bool {
        guard let state = sides[side], !state.selection.isEmpty else {
            return false
        }
        startJob(.trash(selectedPaths(state)))
        return true
    }

    /// The paths are taken now: what is confirmed is exactly what is deleted, even if the
    /// selection changes while the question is open.
    func deleteSelection(_ side: Side, ask: Bool) -> Bool {
        guard let state = sides[side], !state.selection.isEmpty else {
            return false
        }
        let paths = selectedPaths(state)
        if ask {
            nextDeleteToken += 1
            deleteRequest = DeleteRequest(paths: paths, token: nextDeleteToken)
        } else {
            startJob(.delete(paths))
        }
        return true
    }

    func answerDelete(_ token: Int, delete: Bool) -> Bool {
        guard let request = deleteRequest, request.token == token else {
            return false // an old question; a newer one replaced it
        }
        deleteRequest = nil
        if delete {
            startJob(.delete(request.paths))
        }
        return true
    }

    func rename(_ side: Side, _ path: String, to newName: String) -> Bool {
        if sides[side]?.renameRequest?.path == path {
            sides[side]?.renameRequest = nil
        }
        guard newName != Paths.lastComponent(of: path) else {
            return true // the edit ended without a change
        }
        let folder = Paths.parent(of: path) ?? "/"
        startJob(.rename(path, newName: newName)) { workspace in
            workspace.select(newName, in: folder, on: side)
        }
        return true
    }

    func requestRename(_ side: Side) -> Bool {
        guard let state = sides[side], state.selection.count == 1, let name = state.selection.first else {
            return false
        }
        requestRename(of: name, in: state.entriesLocation, on: side)
        return true
    }

    func cancelRename(_ side: Side) -> Bool {
        guard sides[side]?.renameRequest != nil else {
            return false
        }
        sides[side]?.renameRequest = nil
        return true
    }

    func newFolder(_ side: Side) -> Bool {
        guard let state = sides[side] else {
            return false
        }
        let taken = Set(state.allEntries.map { $0.name.lowercased() })
        var name = "New Folder"
        var number = 2
        while taken.contains(name.lowercased()) {
            name = "New Folder \(number)"
            number += 1
        }
        let folder = state.entriesLocation
        startJob(.newFolder(parent: folder, name: name)) { workspace in
            guard workspace.select(name, in: folder, on: side) else {
                return
            }
            workspace.requestRename(of: name, in: folder, on: side)
        }
        return true
    }

    func answerConflict(_ job: Int, _ answer: ConflictAnswer) -> Bool {
        jobQueue.answer(job, answer)
        return false // the job's new state arrives through the queue
    }

    func cancelJob(_ job: Int) -> Bool {
        jobQueue.cancel(job)
        return false
    }

    func dismissJob(_ job: Int) -> Bool {
        jobQueue.dismiss(job)
        return false
    }

    // MARK: Jobs

    private func selectedPaths(_ state: SideState) -> [String] {
        state.selection.sorted().map { Paths.appending($0, to: state.entriesLocation) }
    }

    private func requestRename(of name: String, in folder: String, on side: Side) {
        nextRenameToken += 1
        sides[side]?.renameRequest = RenameRequest(name: name, folder: folder, token: nextRenameToken)
    }

    /// Selects `name` once the side's listing of `folder` shows it, if the side still shows that
    /// folder: a job that finishes after the user went elsewhere selects nothing there.
    @discardableResult
    private func select(_ name: String, in folder: String, on side: Side) -> Bool {
        guard sides[side]?.location == folder else {
            return false
        }
        sides[side]?.pendingSelection = PendingSelection(folder: folder, name: name)
        return true
    }

    private func startJob(_ operation: FileOperation, then followUp: ((Workspace) -> Void)? = nil) {
        let id = jobQueue.start(operation)
        if let followUp {
            jobFollowUps[id] = followUp
        }
    }

    func jobFinished(_ job: Job) {
        let followUp = jobFollowUps.removeValue(forKey: job.id)
        let succeeded = job.state == .finished && job.errors.isEmpty
        if succeeded {
            followUp?(self)
        }
        reload(showing: Self.changedFolders(by: job.operation))
        if succeeded {
            // Only jobs that need attention stay in the list.
            jobQueue.dismiss(job.id)
        }
        notifyChange()
    }

    static func changedFolders(by operation: FileOperation) -> Set<String> {
        func parent(_ path: String) -> String {
            Paths.parent(of: path) ?? "/"
        }
        return switch operation {
        case let .copy(_, folder): [folder]
        case let .move(sources, folder): Set(sources.map(parent)).union([folder])
        case let .trash(paths), let .delete(paths): Set(paths.map(parent))
        case let .command(_, folder): [folder] // e.g. git pull changes the files in it
        case let .rename(path, _): [parent(path)]
        case let .newFolder(folder, _): [folder]
        }
    }
}

/// Items the user asked to delete for good, waiting for confirmation.
public struct DeleteRequest: Equatable, Sendable {
    public let paths: [String]
    /// Changes with every request, so an answer always belongs to the question it was given for.
    public let token: Int
}

public struct SelectedItem: Equatable, Sendable {
    public let path: String
    public let isDirectory: Bool

    public init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
    }

    public var name: String {
        Paths.lastComponent(of: path)
    }
}
