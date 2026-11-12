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
        guard let state = sides[side], state.find == nil, state.selection.count == 1,
              let name = state.selection.first
        else {
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
        guard let state = sides[side], state.find == nil else {
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

    /// The outermost selected items (a search lists a folder and what is in it, #48), so a
    /// question about deleting counts what will be deleted. By name alone, without the disk (the
    /// main thread): one entry is inside another only in search results, and a search never
    /// enters a link, so whatever lies between them is a real folder. The job checks again.
    private func selectedPaths(_ state: SideState) -> [String] {
        FileOperation.outermost(state.selection.sorted().map { Paths.appending($0, to: state.entriesLocation) }) { _ in
            true
        }
    }

    private func requestRename(of name: String, in folder: String, on side: Side) {
        nextRenameToken += 1
        sides[side]?.renameRequest = RenameRequest(name: name, folder: folder, token: nextRenameToken)
    }

    /// Selects `name` once the side's listing of `folder` shows it, if the side still shows that
    /// folder: a job that finishes after the user went elsewhere selects nothing there.
    @discardableResult
    private func select(_ name: String, in folder: String, on side: Side) -> Bool {
        select([name], in: folder, on: side)
    }

    /// Git Clean's removal (#71): a job unless there is nothing to remove.
    func removeExactly(_ plan: RemovalPlan, forGood: Bool) -> Bool {
        guard !plan.isEmpty else {
            return false
        }
        startJob(.removeExactly(plan, forGood: forGood))
        return true
    }

    /// Every side that shows `folder` reads it again and then selects `names`. A fast filter
    /// that lists only some names ends first: what is to be selected must be seen (#70 review).
    func selectAfterReading(_ folder: String, _ names: Set<String>) -> Bool {
        var changed = false
        for side in Side.allCases where sides[side]?.location == folder {
            if sides[side]?.listFilter != nil {
                _ = setQuickFilter(side, nil)
            }
            if select(names, in: folder, on: side) {
                load(side)
                changed = true
            }
        }
        return changed
    }

    /// The same for several names (a batch rename's): those the listing shows are selected.
    @discardableResult
    func select(_ names: Set<String>, in folder: String, on side: Side) -> Bool {
        guard sides[side]?.location == folder else {
            return false
        }
        sides[side]?.pendingSelection = PendingSelection(folder: folder, names: names)
        return true
    }

    @discardableResult
    func startJob(_ operation: FileOperation, then followUp: ((Workspace) -> Void)? = nil) -> Int {
        let id = jobQueue.start(operation)
        if let followUp {
            jobFollowUps[id] = followUp
        }
        return id
    }

    /// Calls `handler` with the job as it ended, whatever the outcome (#43: a dialog that started
    /// it shows how it went). A job that succeeded leaves the list at once, so this is the only
    /// way to see its end.
    public func whenJobDone(_ id: Int, _ handler: @escaping (Job) -> Void) {
        jobObservers[id, default: []].append(handler)
    }

    func jobFinished(_ job: Job) {
        for handler in jobObservers.removeValue(forKey: job.id) ?? [] {
            handler(job)
        }
        recordUndo(of: job)
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
        case let .renameAll(renames): Set(renames.map { parent($0.path) })
        case let .newFolder(folder, _): [folder]
        case let .removeExactly(plan, _): Set((plan.files + plan.folders).map { parent(plan.root + "/" + $0.relative) })
        case let .undo(steps): Set(steps.flatMap { step -> [String] in
                switch step {
                case let .trash(path, _): [parent(path)]
                case let .move(source, target, _): [parent(source), parent(target)]
                case let .rename(renames, _): renames.map { parent($0.path) }
                case let .makeFolder(path, _): [parent(path)]
                }
            })
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

extension Workspace {
    /// Reads the side's folder again if it shows one of `folders`; a search (#48) runs again if
    /// one of them is below the folder it searched.
    func reload(showing folders: Set<String>) {
        for side in Side.allCases {
            guard let state = sides[side] else {
                continue
            }
            let shows = state.find == nil ? folders.contains(state.location)
                : folders.contains { $0 == state.location || Paths.contains($0, in: state.location) }
            if shows {
                load(side)
            }
        }
    }
}
