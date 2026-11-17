import BlitterCore
import Foundation

/// The state of one window: both sides, which of them is active, and the view options. What
/// all windows share (the settings, the jobs, the notices) is `app`'s (#96).
@MainActor
public final class Workspace {
    public typealias Lister = @Sendable (String) async throws -> [DirectoryEntry]
    public typealias DirectoryCheck = @Sendable (String) async -> Bool
    public typealias VolumeList = @Sendable () async -> [MountedVolume]
    public typealias WatcherFactory = (@escaping @Sendable ([FolderChange]) -> Void) -> any FolderWatching

    /// What every window shares (#96).
    public let app: AppModel
    var sides: [Side: SideState]
    let home: String
    let lister: Lister
    let directoryCheck: DirectoryCheck
    let volumes: VolumeList
    /// How this window's watcher is made; another window makes its own the same way.
    let makeWatcher: WatcherFactory
    /// Git (#22): the working copies whose status is known, by root; reading them; and how.
    var gitRepositories: [String: KnownRepository] = [:]
    var gitWork: [Side: Task<Void, Never>] = [:]
    var gitPolling: Task<Void, Never>?
    /// How often visible working copies are read again (tests make it short).
    var gitRefreshInterval: TimeInterval = 60
    public var gitAccess = GitAccess.real
    /// Increases whenever a git state changes, so views know when to look again.
    public internal(set) var gitVersion = 0
    /// Opening, revealing, Quick Look and the clipboard, provided by the app.
    public var system = SystemServices()
    /// Places at the top of every side's tree: favorites, volumes, cloud drives.
    public internal(set) var treeRoots: [TreeRoot]
    /// Volumes, iCloud Drive and the CloudStorage providers, each read and published on its own,
    /// so a stalled cloud drive cannot hold back the volumes.
    var rootParts: [TreeRoots.Part: [TreeRoot]] = [:]
    var rootsWork: [TreeRoots.Part: Task<Void, Never>] = [:]
    /// Subfolder reads per side and folder path.
    var treeWork: [Side: [String: Task<Void, Never>]] = [:]
    /// Who wants to know how a job this window started ended (`whenJobDone`).
    var jobObservers: [Int: [(Job) -> Void]] = [:]
    /// What to do after a job this window started succeeded, e.g. select a renamed item.
    var jobFollowUps: [Int: (Workspace) -> Void] = [:]
    /// The automation client whose action is being carried out, for its jobs' origin (#112).
    var automationClient: String?
    var nextRenameToken = 0
    /// Watches the folders both sides show, and the expanded tree folders, for changes on disk.
    var watcher: (any FolderWatching)?
    var watchedFolders: Set<String> = []
    /// The running load or re-sort per side. A new one cancels the previous one.
    var pendingWork: [Side: Task<Void, Never>] = [:]
    /// Find (#48): the running search per side, and the flag that stops its walk early.
    var findWork: [Side: Task<Void, Never>] = [:]
    var findStops: [Side: CancellationFlag] = [:]
    /// Each side's search and folder measuring as listed with the jobs (#112).
    var findTasks: [Side: Int] = [:]
    var folderSizeTasks: [Side: Int] = [:]
    /// The side's measuring request: how many folders, how many measured so far.
    var folderSizeRequests: [Side: (total: Int, done: Int)] = [:]
    /// The fast filter's search for highlighted names (#39). A newer one cancels it.
    var highlightWork: [Side: Task<Void, Never>] = [:]
    /// Starting the diff tool (#40): finding it and launching it; tests replace both.
    var compareWork: Task<Void, Never>?
    public var findDiffTool: @Sendable () -> DiffTool? = { DiffTool.detect() }
    public var launchTool: @Sendable ([String], [String: String]) throws -> Void = { try Launcher.launch(
        $0,
        environment: $1
    ) }
    /// Free space (#51): the read running per side, the sides whose listing changed meanwhile,
    /// and how it is read (tests replace it).
    var freeSpaceWork: [Side: Task<Void, Never>] = [:]
    /// Folder sizes being measured (#52), and the flag that stops the walk.
    var folderSizeWork: [Side: Task<Void, Never>] = [:]
    var folderSizeStops: [Side: CancellationFlag] = [:]
    /// Matching a pattern for the selection, per side.
    var patternWork: [Side: Task<Void, Never>] = [:]
    /// Select Differences comparing the two listings (#108); a newer one replaces it.
    var differenceWork: Task<Void, Never>?
    /// How a folder is measured (tests hold it back).
    var measureFolder: @Sendable (String, CancellationFlag) -> Int64? = { FolderSizes.measure($0, cancelled: $1) }
    var freeSpaceWanted: Set<Side> = []
    public var readFreeSpace: @Sendable (String) async -> Int64? = BlitterCore.freeSpace(at:)
    /// A symbolic link being checked before it is opened. Any navigation cancels it.
    var pendingOpen: [Side: Task<Void, Never>] = [:]
    var clock: @Sendable () -> Date = Date.init // for the recent folders' frecency (#74); tests set it

    /// The source side. File operations go from here to the opposite side.
    public internal(set) var activeSide: Side = .left
    public internal(set) var showsHiddenFiles = false

    /// Called after every state change.
    public var onChange: (() -> Void)?
    /// Items waiting for the user to confirm that they are deleted for good; the window asks.
    public internal(set) var deleteRequest: DeleteRequest?
    var nextDeleteToken = 0
    /// A change an automation client asked for, waiting for the user's answer in Blitter (#58),
    /// and how the waiting request is resumed.
    public internal(set) var automationConfirmation: AutomationConfirmation?
    var automationAnswer: CheckedContinuation<Bool, Never>?
    var nextAutomationToken = 0
    /// Batch Rename asked for, waiting for the window to show it.
    public internal(set) var batchRenameRequest: BatchRenameRequest?
    var nextBatchRenameToken = 0
    /// The first window: it makes what all windows share, and reads the settings file.
    public convenience init(initialLocation: String = UserPaths.home, home: String = UserPaths.home,
                            lister: @escaping Lister = listDirectory,
                            directoryCheck: @escaping DirectoryCheck = isDirectory,
                            volumes: @escaping VolumeList = mountedVolumes,
                            watcher makeWatcher: @escaping WatcherFactory = { FolderWatcher(onChange: $0) },
                            jobs: JobQueue = JobQueue(), restoring saved: WorkspaceState? = nil,
                            settingsFile: String? = nil)
    {
        let app = AppModel(settingsFile: settingsFile, jobs: jobs,
                           favorites: saved?.favorites ?? TreeRoots.defaultFavorites(home: home))
        self.init(app: app, initialLocation: initialLocation, home: home, lister: lister,
                  directoryCheck: directoryCheck, volumes: volumes, watcher: makeWatcher, restoring: saved)
        loadSettings()
    }

    /// Another window (#96): what `other` shares, folders read the same way, and its own sides —
    /// as saved, or both at `location`.
    public convenience init(sharingWith other: Workspace, location: String, restoring saved: WorkspaceState? = nil) {
        self.init(app: other.app, initialLocation: location, home: other.home, lister: other.lister,
                  directoryCheck: other.directoryCheck, volumes: other.volumes, watcher: other.makeWatcher,
                  restoring: saved)
        system = other.system
        gitAccess = other.gitAccess
        gitRefreshInterval = other.gitRefreshInterval
        findDiffTool = other.findDiffTool
        launchTool = other.launchTool
        readFreeSpace = other.readFreeSpace
        measureFolder = other.measureFolder
        clock = other.clock
    }

    private init(app: AppModel, initialLocation: String, home: String, lister: @escaping Lister,
                 directoryCheck: @escaping DirectoryCheck, volumes: @escaping VolumeList,
                 watcher makeWatcher: @escaping WatcherFactory, restoring saved: WorkspaceState?)
    {
        self.app = app
        sides = [.left: SideState(location: initialLocation), .right: SideState(location: initialLocation)]
        if let saved {
            sides = [.left: SideState(restoring: saved.left), .right: SideState(restoring: saved.right)]
            showsHiddenFiles = saved.showsHiddenFiles
        }
        self.home = home
        self.lister = lister
        self.directoryCheck = directoryCheck
        self.volumes = volumes
        self.makeWatcher = makeWatcher
        treeRoots = []
        app.add(self)
        treeRoots = TreeRoots.favorites(favorites, home: home) // the file's, if already read
        // The settings are final (the defaults only, or already read for another window): a
        // saved sort must be on a shown column.
        if app.settingsFile == nil || app.settingsReads > 0 {
            for side in Side.allCases where sortsByHiddenColumn(side) {
                sides[side]?.sort = ListSort()
            }
        }
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
    }

    public func state(of side: Side) -> SideState {
        sides[side]! // swiftlint:disable:this force_unwrapping
    }

    public func perform(_ command: Command) {
        if apply(command) {
            notifyChange()
        }
    }

    // swiftlint:disable function_body_length
    /// Carries out the command. Returns false if it changed nothing, so nobody is notified. One
    /// line per command: a table, not logic to split.
    func apply(_ command: Command) -> Bool {
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
        case let .showColumn(side, column, shown): showColumn(side, column, shown)
        case let .resetColumns(side): resetColumns(side)
        case let .setQuickFilter(side, filter): setQuickFilter(side, filter)
        case let .selectQuickFilterMatch(side, forward): selectQuickFilterMatch(side, forward: forward)
        case let .select(side, names): select(side, names)
        case .toggleHiddenFiles: toggleHiddenFiles()
        case .toggleDragDrop: toggleDragDrop()
        case let .saveSettings(original, edited): saveSettings(from: original, to: edited)
        case let .tryTheme(theme): tryTheme(theme)
        case let .newWindow(folder): openWindow(at: folder)
        case let .zoomFont(zoom): zoomFont(zoom)
        case let .find(side, pattern, contents): find(side, pattern, containing: contents)
        case let .stopFind(side): stopFind(side)
        case let .measureFolderSizes(side): measureFolders(side)
        case .selectDifferences: selectDifferences()
        case let .selectByPattern(side, pattern, mode, folders):
            selectByPattern(side, pattern, mode, includesFolders: folders)
        case let .requestBatchRename(side): requestBatchRename(side)
        case let .batchRename(side, preview): batchRename(side, preview)
        case .cancelBatchRename: cancelBatchRename()
        case let .answerAutomation(token, allow): answerAutomation(token, allow: allow)
        case let .showNotice(text): showNotice(text)
        case let .addFavorite(path): addFavorite(path)
        case let .removeFavorite(path): removeFavorite(path)
        case let .moveFavorite(path, offset): moveFavorite(path, by: offset)
        case let .undo(entry): undo(entry)
        case let .recentFolder(side, path, change): changeRecentFolder(side, path, change)
        case let .selectAfterReading(folder, names): selectAfterReading(folder, names)
        case let .removeExactly(plan, forGood): removeExactly(plan, forGood: forGood)
        case .copyToOtherSide: transferSelection(move: false)
        case .moveToOtherSide: transferSelection(move: true)
        case let .copyItems(paths, folder): transfer(paths, into: folder, move: false)
        case let .moveItems(paths, folder): transfer(paths, into: folder, move: true)
        case let .trashSelection(side): trashSelection(side)
        case let .deleteSelection(side): deleteSelection(side, ask: settings.confirmDelete)
        case let .deleteSelectionWithoutAsking(side): deleteSelection(side, ask: false)
        case let .answerDelete(token, delete): answerDelete(token, delete: delete)
        case let .revealInFinder(side): withSelection(side, system.reveal)
        case let .openWithApp(app, paths, title): openWithApp(app, paths, title: title)
        case let .setDefaultApp(app, kind): setDefaultApp(app, for: kind)
        case let .chooseApp(target): chooseApp(for: target)
        case let .runCommand(arguments, folder): runCommand(arguments, in: folder)
        case let .compare(left, right): compare(left, right)
        case let .present(request): present(request)
        case let .eject(path): eject(path)
        case let .togglePreview(side): togglePreview(side)
        case let .copyToPasteboard(side): withSelection(side, system.copyToPasteboard)
        case let .copyPaths(side): withSelection(side) { system.copyText($0.map(\.path).joined(separator: "\n")) }
        case let .copyNames(side): withSelection(side) { system.copyText($0.map(\.name).joined(separator: "\n")) }
        case let .copyFolderPath(side): copyFolderPath(side)
        case .openSettingsFile: openSettingsFile()
        case let .dismissNotice(id): dismissNotice(id)
        case let .rename(side, path, newName): rename(side, path, to: newName)
        case let .requestRename(side): requestRename(side)
        case let .cancelRename(side): cancelRename(side)
        case let .newFolder(side): newFolder(side)
        case let .answerConflict(job, answer): answerConflict(job, answer)
        case let .cancelJob(job): cancelJob(job)
        case let .startJobNow(job): startJobNow(job)
        case let .cancelTask(task): cancelTask(task)
        case let .dismissJob(job): dismissJob(job)
        case let .runAction(id, side): runAction(id, on: side)
        case let .runFolderAction(id, side, folder): runFolderAction(id, on: side, folder: folder)
        }
    }
    // swiftlint:enable function_body_length
}

// MARK: Loading

extension Workspace {
    /// Reads the side's folder, then filters and sorts it, all off the main thread.
    private func startAtHome(_ side: Side, _ restored: SideState) {
        var state = restored
        state.fallsBackToHome = false
        state.location = home
        sides[side] = state
        pendingWork[side] = nil
        load(side)
        revealInTree(side, preferredRoot: nil)
        notifyChange()
    }

    func load(_ side: Side) {
        guard let state = sides[side] else {
            return
        }
        guard state.find == nil else {
            runFind(side, fresh: false) // the results are the side's listing (#48)
            return
        }
        sides[side]?.status = .loading
        let lister = lister
        let showHidden = showsHiddenFiles
        startWork(on: side, location: state.location) {
            let entries = try await lister(state.location)
            let visible = Listing.visibleEntries(entries, showHidden: showHidden, sort: state.sort,
                                                 filter: state.listFilter, folderSizes: state.measuredSizes)
            return Listing.Result(all: entries, visible: visible)
        }
    }

    /// Filters and sorts the already loaded entries again, e.g. after the sort order changed.
    func relist(_ side: Side) {
        guard let state = sides[side], state.status == .loaded else {
            // A load in progress picks up the new options when it starts; restart it.
            if sides[side]?.status == .loading {
                load(side)
            }
            return
        }
        let showHidden = showsHiddenFiles
        startWork(on: side, location: state.entriesLocation) {
            Listing.Result(all: state.allEntries, visible: Listing.visibleEntries(
                state.allEntries, showHidden: showHidden, sort: state.sort, filter: state.listFilter,
                folderSizes: state.measuredSizes
            ))
        }
    }

    /// Runs `work`, which lists or re-sorts the folder at `location`, and stores its result unless
    /// newer work for the side replaced it in the meantime.
    func startWork(on side: Side, location: String,
                   _ work: @escaping @Sendable () async throws -> Listing.Result)
    {
        pendingWork[side]?.cancel()
        pendingWork[side] = Task { [weak self] in
            let result: Result<Listing.Result, Error>
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
                        with result: Result<Listing.Result, Error>)
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
        case let .success(listing):
            state.fallsBackToHome = false
            state.allEntries = listing.all
            state.visibleEntries = listing.visible
            state.visibleIndex = listing.index
            state.totals = listing.totals
            state.status = .loaded
            // Keep only selected names that still exist (looked up, not searched: #47).
            state.selection = state.selection.filter { listing.index[$0] != nil }
            state.folderSizes = Self.keepingListedFolders(state.folderSizes, in: listing.all)
            if let pending = state.pendingSelection, pending.folder == location {
                let listed = pending.names.filter { listing.index[$0] != nil }
                if !listed.isEmpty {
                    state.selection = listed
                    state.pendingSelection = nil
                }
            }
        case .failure where state.fallsBackToHome && location != home:
            // A folder from the last session that is gone: start at home, without an error.
            startAtHome(side, state)
            return
        case let .failure(error):
            state.allEntries = []
            state.visibleEntries = []
            state.visibleIndex = [:]
            state.totals = EntryTotals()
            state.selection = []
            state.status = .failed(Paths.listingMessage(for: error, location: location))
        }
        state.entriesVersion += 1
        sides[side] = state
        pendingWork[side] = nil
        listingArrived(side)
        notifyChange()
    }
}
