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
    /// The user's configuration; defaults until the settings file has been read.
    public internal(set) var settings = Settings() {
        didSet { settingsChanged(from: oldValue) }
    }

    /// Messages for the user that stay until dismissed, e.g. problems in the settings file.
    public internal(set) var notices: [Notice] = []
    var nextNoticeID = 0
    var settingsNotice: Notice?
    /// The settings file, or nil to use the defaults only (tests).
    let settingsFile: String?
    var settingsWork: Task<Void, Never>?
    /// A zoomed font size not yet in the settings file (#63), and the saves writing it there,
    /// one after the other.
    public internal(set) var pendingFontSize: Double?
    var fontSizeSave: Task<Void, Never>?
    var fontSizeSaveGeneration = 0
    /// How long zooming must pause before the size is saved: a wheel zooms in many steps.
    var fontSizeSaveDelay: Duration = .milliseconds(500)
    /// Tests: runs between reading the settings file and replacing it (a zoom's or the Settings
    /// window's save), as an editor's save might.
    var settingsFileBeforeReplace: (@Sendable () -> Void)?
    /// The Settings window's save (#64), and how often the settings were read: the window reads
    /// the file again when it changed and nothing is edited.
    var settingsSave: Task<Void, Never>?
    var settingsSaveGeneration = 0
    var lastSettingsSaveProblem: String?
    public internal(set) var settingsReads = 0
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
    /// Favorites from the window state (the file's list wins), one not yet saved there, its save (#72).
    var stateFavorites: [String], pendingFavorites: [String]?, favoritesSave: Task<Void, Never>?, favoritesSaves = 0
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
    /// Who wants to know how a job ended (`whenJobDone`).
    var jobObservers: [Int: [(Job) -> Void]] = [:]
    /// What to do after a job succeeded, e.g. select a renamed item.
    var jobFollowUps: [Int: (Workspace) -> Void] = [:]
    /// How to undo the jobs done, oldest first (#61).
    public internal(set) var undoJournal: [UndoEntry] = []
    var nextUndoID = 0
    /// The undo job running, if any (#61).
    var runningUndo: Int?
    var nextRenameToken = 0
    /// Watches the folders both sides show, and the expanded tree folders, for changes on disk.
    var watcher: (any FolderWatching)?
    var watchedFolders: Set<String> = []
    /// The running load or re-sort per side. A new one cancels the previous one.
    var pendingWork: [Side: Task<Void, Never>] = [:]
    /// Find (#48): the running search per side, and the flag that stops its walk early.
    var findWork: [Side: Task<Void, Never>] = [:]
    var findStops: [Side: CancellationFlag] = [:]
    /// The fast filter's search for highlighted names (#39). A newer one cancels it.
    var highlightWork: [Side: Task<Void, Never>] = [:]
    /// Starting the diff tool (#40): finding it and launching it; tests replace both.
    var compareWork: Task<Void, Never>?
    public var findDiffTool: @Sendable () -> DiffTool? = { DiffTool.detect() }
    public var launchTool: @Sendable ([String], [String: String]) throws -> Void = { try Launcher.launch(
        $0,
        environment: $1
    ) }
    /// Color schemes being fetched, by the name the settings give them (#34), and how.
    var schemeWork: [String: Task<Void, Never>] = [:]
    public var fetch: @Sendable (URL) async throws -> Data = Downloads.fetch
    /// Free space (#51): the read running per side, the sides whose listing changed meanwhile,
    /// and how it is read (tests replace it).
    var freeSpaceWork: [Side: Task<Void, Never>] = [:]
    /// Folder sizes being measured (#52), and the flag that stops the walk.
    var folderSizeWork: [Side: Task<Void, Never>] = [:]
    var folderSizeStops: [Side: CancellationFlag] = [:]
    /// Matching a pattern for the selection, per side.
    var patternWork: [Side: Task<Void, Never>] = [:]
    /// How a folder is measured (tests hold it back).
    var measureFolder: @Sendable (String, CancellationFlag) -> Int64? = { FolderSizes.measure($0, cancelled: $1) }
    var freeSpaceWanted: Set<Side> = []
    public var readFreeSpace: @Sendable (String) async -> Int64? = BlitterCore.freeSpace(at:)
    /// A symbolic link being checked before it is opened. Any navigation cancels it.
    var pendingOpen: [Side: Task<Void, Never>] = [:]
    static let maxRecentLocations = 20

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
    /// Every action the user can run, by id (#15).
    /// Built from the settings' tools; replaced when they change.
    public internal(set) var actionRegistry = ActionRegistry(tools: Tool.defaults)

    public init(initialLocation: String = UserPaths.home, home: String = UserPaths.home,
                lister: @escaping Lister = listDirectory, directoryCheck: @escaping DirectoryCheck = isDirectory,
                volumes: @escaping VolumeList = mountedVolumes,
                watcher makeWatcher: WatcherFactory = { FolderWatcher(onChange: $0) },
                jobs: JobQueue = JobQueue(), restoring saved: WorkspaceState? = nil, settingsFile: String? = nil)
    {
        jobQueue = jobs
        self.settingsFile = settingsFile
        sides = [.left: SideState(location: initialLocation), .right: SideState(location: initialLocation)]
        stateFavorites = saved?.favorites ?? TreeRoots.defaultFavorites(home: home)
        if let saved {
            sides = [.left: SideState(restoring: saved.left), .right: SideState(restoring: saved.right)]
            showsHiddenFiles = saved.showsHiddenFiles
        }
        self.home = home
        self.lister = lister
        self.directoryCheck = directoryCheck
        self.volumes = volumes
        treeRoots = TreeRoots.favorites(stateFavorites, home: home)
        if settingsFile == nil { // the default settings are final: a saved sort must be on a shown column
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
        loadSettings()
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
        case let .saveSettings(original, edited): saveSettings(from: original, to: edited)
        case let .zoomFont(zoom): zoomFont(zoom)
        case let .find(side, pattern, contents): find(side, pattern, containing: contents)
        case let .stopFind(side): stopFind(side)
        case let .measureFolderSizes(side): measureFolders(side)
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
        case let .runCommand(arguments, folder): runCommand(arguments, in: folder)
        case let .compare(left, right): compare(left, right)
        case let .present(request): present(request)
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
        state.recentLocations = [home]
        sides[side] = state
        pendingWork[side] = nil
        load(side)
        revealInTree(side, preferredRoot: nil)
        notifyChange()
    }

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
