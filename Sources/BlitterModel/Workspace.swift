import BlitterCore
import Foundation

/// The state of the whole window: both sides, which of them is active, and the view options.
@MainActor
public final class Workspace {
    public typealias Lister = @Sendable (String) async throws -> [DirectoryEntry]
    public typealias DirectoryCheck = @Sendable (String) async -> Bool
    public typealias VolumeList = @Sendable () async -> [MountedVolume]
    public typealias WatcherFactory = (@escaping @Sendable ([FolderChange]) -> Void) -> any FolderWatching

    var sides: [Side: SideState]
    let home: String
    let lister: Lister
    let directoryCheck: DirectoryCheck
    let volumes: VolumeList
    /// Places at the top of every side's tree: favorites, volumes, cloud drives.
    public internal(set) var treeRoots: [TreeRoot]
    /// Volumes, iCloud Drive and the CloudStorage providers, each read and published on its own,
    /// so a stalled cloud drive cannot hold back the volumes.
    var rootParts: [TreeRoots.Part: [TreeRoot]] = [:]
    var rootsWork: [TreeRoots.Part: Task<Void, Never>] = [:]
    /// Subfolder reads per side and folder path.
    var treeWork: [Side: [String: Task<Void, Never>]] = [:]
    /// File operations in the background.
    let jobQueue: JobQueue
    /// What to do after a job succeeded, e.g. select a renamed item.
    var jobFollowUps: [Int: (Workspace) -> Void] = [:]
    var nextRenameToken = 0
    /// Watches the folders both sides show, and the expanded tree folders, for changes on disk.
    var watcher: (any FolderWatching)?
    var watchedFolders: Set<String> = []
    /// The running load or re-sort per side. A new one cancels the previous one.
    private(set) var pendingWork: [Side: Task<Void, Never>] = [:]
    /// A symbolic link being checked before it is opened. Any navigation cancels it.
    private(set) var pendingOpen: [Side: Task<Void, Never>] = [:]
    private static let maxRecentLocations = 20

    /// The source side. File operations go from here to the opposite side.
    public private(set) var activeSide: Side = .left
    public private(set) var showsHiddenFiles = false

    /// Called after every state change.
    public var onChange: (() -> Void)?

    public init(initialLocation: String = UserPaths.home, home: String = UserPaths.home,
                lister: @escaping Lister = listDirectory, directoryCheck: @escaping DirectoryCheck = isDirectory,
                volumes: @escaping VolumeList = mountedVolumes,
                watcher makeWatcher: WatcherFactory = { FolderWatcher(onChange: $0) },
                jobs: JobQueue = JobQueue())
    {
        jobQueue = jobs
        sides = [.left: SideState(location: initialLocation), .right: SideState(location: initialLocation)]
        self.home = home
        self.lister = lister
        self.directoryCheck = directoryCheck
        self.volumes = volumes
        treeRoots = TreeRoots.favorites(home: home)
        // Before anything is read: the watcher reports every change from the moment it exists,
        // so nothing that happens while the folders are being read can be missed.
        watcher = makeWatcher { [weak self] changes in
            Task { @MainActor in self?.foldersChanged(changes) }
        }
        for side in Side.allCases {
            load(side)
            revealInTree(side, preferredRoot: nil)
        }
        loadTreeRoots()
        updateWatchedFolders()
        jobs.onChange = { [weak self] in self?.notifyChange() }
        jobs.onFinish = { [weak self] job in self?.jobFinished(job) }
    }

    public func state(of side: Side) -> SideState {
        sides[side]! // swiftlint:disable:this force_unwrapping
    }

    public func perform(_ command: Command) {
        if apply(command) {
            notifyChange()
        }
    }

    /// Carries out the command. Returns false if it changed nothing, so nobody is notified.
    private func apply(_ command: Command) -> Bool {
        switch command {
        case let .navigate(side, path): navigate(side, path)
        case let .open(side, name): open(side, name)
        case let .goBack(side): go(side, .back)
        case let .goForward(side): go(side, .forward)
        case let .goToParent(side): goToParent(side)
        case let .expandTreeNode(side, node): expandTreeNode(side, node)
        case let .collapseTreeNode(side, node): collapseTreeNode(side, node)
        case let .selectTreeNode(side, node): selectTreeNode(side, node)
        case .refreshTreeRoots: refreshTreeRoots()
        case .switchActiveSide: activate(activeSide.opposite)
        case let .activate(side): activate(side)
        case let .refresh(side): refresh(side)
        case let .sort(side, order): sort(side, order)
        case let .select(side, names): select(side, names)
        case .toggleHiddenFiles: toggleHiddenFiles()
        case .copyToOtherSide: transferSelection(move: false)
        case .moveToOtherSide: transferSelection(move: true)
        case let .copyItems(paths, side): transfer(paths, into: side, move: false)
        case let .moveItems(paths, side): transfer(paths, into: side, move: true)
        case let .trashSelection(side): trashSelection(side)
        case let .rename(side, path, newName): rename(side, path, to: newName)
        case let .requestRename(side): requestRename(side)
        case let .cancelRename(side): cancelRename(side)
        case let .newFolder(side): newFolder(side)
        case let .answerConflict(job, answer): answerConflict(job, answer)
        case let .cancelJob(job): cancelJob(job)
        case let .dismissJob(job): dismissJob(job)
        }
    }

    // MARK: Loading

    /// Reads the side's folder, then filters and sorts it, all off the main thread.
    /// Reads the side's folder again if it shows one of `folders`.
    func reload(showing folders: Set<String>) {
        for side in Side.allCases where sides[side].map({ folders.contains($0.location) }) == true {
            load(side)
        }
    }

    func load(_ side: Side) {
        guard let state = sides[side] else {
            return
        }
        sides[side]?.status = .loading
        let lister = lister
        let showHidden = showsHiddenFiles
        startWork(on: side, location: state.location) {
            let entries = try await lister(state.location)
            let visible = Listing.visibleEntries(entries, showHidden: showHidden, sort: state.sort)
            return (entries, visible)
        }
    }

    /// Filters and sorts the already loaded entries again, e.g. after the sort order changed.
    private func relist(_ side: Side) {
        guard let state = sides[side], state.status == .loaded else {
            // A load in progress picks up the new options when it starts; restart it.
            if sides[side]?.status == .loading {
                load(side)
            }
            return
        }
        let showHidden = showsHiddenFiles
        startWork(on: side, location: state.entriesLocation) {
            (state.allEntries, Listing.visibleEntries(state.allEntries, showHidden: showHidden, sort: state.sort))
        }
    }

    /// Runs `work`, which lists or re-sorts the folder at `location`, and stores its result unless
    /// newer work for the side replaced it in the meantime.
    private func startWork(on side: Side, location: String,
                           _ work: @escaping @Sendable () async throws -> ([DirectoryEntry], [ListedEntry]))
    {
        pendingWork[side]?.cancel()
        pendingWork[side] = Task { [weak self] in
            let result: Result<([DirectoryEntry], [ListedEntry]), Error>
            do {
                // `work` is nonisolated, so it runs off the main actor, and as a child of this task
                // it sees cancellation.
                result = try await .success(work())
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled, let self else {
                return
            }
            finish(side, location: location, with: result)
        }
    }

    private func finish(_ side: Side, location: String,
                        with result: Result<([DirectoryEntry], [ListedEntry]), Error>)
    {
        guard var state = sides[side] else {
            return
        }
        // A selection belongs to the listing it was made in: a listing of another folder starts
        // without one, so a command never applies names to the wrong folder.
        if state.entriesLocation != location {
            state.selection = []
        }
        state.entriesLocation = location
        switch result {
        case let .success((all, visible)):
            state.allEntries = all
            state.visibleEntries = visible
            state.status = .loaded
            // Keep only selected names that still exist.
            let visibleNames = Set(visible.map(\.entry.name))
            state.selection.formIntersection(visibleNames)
            if let pending = state.pendingSelection, pending.folder == location, visibleNames.contains(pending.name) {
                state.selection = [pending.name]
                state.pendingSelection = nil
            }
        case let .failure(error):
            state.allEntries = []
            state.visibleEntries = []
            state.selection = []
            state.status = .failed(Self.message(for: error, location: location))
        }
        state.entriesVersion += 1
        sides[side] = state
        pendingWork[side] = nil
        notifyChange()
    }

    private static func message(for error: Error, location: String) -> String {
        if let posix = error as? POSIXError {
            return "\(location): \(String(cString: strerror(posix.code.rawValue)))"
        }
        return "\(location): \(error.localizedDescription)"
    }
}

// MARK: View options

extension Workspace {
    private func activate(_ side: Side) -> Bool {
        guard activeSide != side else {
            return false
        }
        activeSide = side
        return true
    }

    private func refresh(_ side: Side) -> Bool {
        load(side)
        return true
    }

    private func sort(_ side: Side, _ order: ListSort) -> Bool {
        guard sides[side]?.sort != order else {
            return false
        }
        sides[side]?.sort = order
        relist(side)
        return true
    }

    private func select(_ side: Side, _ names: Set<String>) -> Bool {
        guard sides[side]?.selection != names else {
            return false
        }
        sides[side]?.selection = names
        return true
    }

    private func toggleHiddenFiles() -> Bool {
        showsHiddenFiles.toggle()
        for side in Side.allCases {
            relist(side)
            sides[side]?.tree.version += 1
        }
        return true
    }
}

// MARK: Navigation

extension Workspace {
    private func navigate(_ side: Side, _ input: String) -> Bool {
        guard let state = sides[side], let path = Paths.resolve(input, relativeTo: state.location, home: home) else {
            return false
        }
        return go(side, .path(path))
    }

    private func goToParent(_ side: Side) -> Bool {
        guard let parent = sides[side].flatMap({ Paths.parent(of: $0.location) }) else {
            return false
        }
        return go(side, .path(parent))
    }

    enum Destination {
        case path(String)
        case back
        case forward
    }

    /// Moves the side to another folder, records it in the history, starts reading it and reveals
    /// it in the tree, under `treeRoot` if given. The old listing stays visible until the new one
    /// arrives. Returns false if there is nowhere to go.
    @discardableResult
    func go(_ side: Side, _ destination: Destination, treeRoot: String? = nil) -> Bool {
        guard var state = sides[side] else {
            return false
        }
        let previous = state.location
        let location: String
        switch destination {
        case let .path(path):
            guard path != previous else {
                cancelPendingOpen(side)
                load(side)
                return true
            }
            state.backStack.append(previous)
            state.forwardStack.removeAll()
            location = path
        case .back:
            guard let target = state.backStack.popLast() else {
                return false
            }
            state.forwardStack.append(previous)
            location = target
        case .forward:
            guard let target = state.forwardStack.popLast() else {
                return false
            }
            state.backStack.append(previous)
            location = target
        }
        state.location = location
        state.recentLocations.removeAll { $0 == location }
        state.recentLocations.insert(location, at: 0)
        if state.recentLocations.count > Self.maxRecentLocations {
            state.recentLocations.removeLast()
        }
        // Coming up out of a folder selects it once the parent's listing is there, so the user sees
        // where they came from. Until then the old rows are shown, with nothing selected.
        state.selection = []
        state.renameRequest = nil
        state.pendingSelection = Paths.parent(of: previous) == location
            ? PendingSelection(folder: location, name: Paths.lastComponent(of: previous)) : nil
        sides[side] = state
        cancelPendingOpen(side)
        load(side)
        revealInTree(side, preferredRoot: treeRoot)
        return true
    }

    /// A navigation the user asked for wins over a symbolic link still being checked.
    private func cancelPendingOpen(_ side: Side) {
        pendingOpen[side]?.cancel()
        pendingOpen[side] = nil
    }

    /// Opens a folder entry in this side. Returns true if the state changed now; a symbolic link
    /// is first checked in the background and opened only if it leads to a folder.
    private func open(_ side: Side, _ name: String) -> Bool {
        guard let state = sides[side],
              let listed = state.visibleEntries.first(where: { $0.entry.name == name })
        else {
            return false
        }
        let path = Paths.appending(name, to: state.entriesLocation)
        switch listed.entry.kind {
        case .directory where !listed.contentType.conforms(to: .package):
            return go(side, .path(path))
        case .symlink:
            let directoryCheck = directoryCheck
            pendingOpen[side]?.cancel()
            pendingOpen[side] = Task { [weak self] in
                let isFolder = await directoryCheck(path)
                guard !Task.isCancelled, let self else {
                    return
                }
                pendingOpen[side] = nil
                guard isFolder else {
                    return
                }
                go(side, .path(path))
                notifyChange()
            }
            return false
        default:
            // Files and packages will open in their app (#8).
            return false
        }
    }
}
