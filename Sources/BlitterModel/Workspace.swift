import BlitterCore
import Foundation

/// Everything the user can do. The UI (and later the MCP server) changes state only through these.
public enum Command: Sendable {
    /// Go to a path the user typed. `~`, relative paths and `..` are resolved against the side's
    /// folder. Going to the folder the side already shows reads it again.
    case navigate(Side, path: String)
    /// Open the entry with this name: a folder, or a symbolic link to one, is shown in this side.
    /// Files and packages are not opened yet.
    case open(Side, name: String)
    case goBack(Side)
    case goForward(Side)
    /// Go to the enclosing folder and select the folder we came from.
    case goToParent(Side)
    /// Expand a folder in the side's tree; its subfolders are read in the background.
    case expandTreeNode(Side, TreeNodeID)
    case collapseTreeNode(Side, TreeNodeID)
    /// Show the tree node's folder in the side, keeping the tree selection under that node's root.
    case selectTreeNode(Side, TreeNodeID)
    /// Read the mounted volumes and cloud drives again, e.g. after a volume was mounted.
    case refreshTreeRoots
    /// Make the other side the active (source) side.
    case switchActiveSide
    /// Make this side the active (source) side, e.g. when the user clicks into it.
    case activate(Side)
    /// Read the side's folder again.
    case refresh(Side)
    case sort(Side, ListSort)
    /// Replace the side's selection with these entry names.
    case select(Side, Set<String>)
    /// Show or hide hidden files on both sides.
    case toggleHiddenFiles
}

/// The state of the whole window: both sides, which of them is active, and the view options.
@MainActor
public final class Workspace {
    public typealias Lister = @Sendable (String) async throws -> [DirectoryEntry]
    public typealias DirectoryCheck = @Sendable (String) async -> Bool
    public typealias VolumeList = @Sendable () async -> [MountedVolume]

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
                volumes: @escaping VolumeList = mountedVolumes)
    {
        sides = [.left: SideState(location: initialLocation), .right: SideState(location: initialLocation)]
        self.home = home
        self.lister = lister
        self.directoryCheck = directoryCheck
        self.volumes = volumes
        treeRoots = TreeRoots.favorites(home: home)
        for side in Side.allCases {
            load(side)
            revealInTree(side, preferredRoot: nil)
        }
        loadTreeRoots()
    }

    public func state(of side: Side) -> SideState {
        sides[side]! // swiftlint:disable:this force_unwrapping
    }

    public func perform(_ command: Command) {
        if apply(command) {
            onChange?()
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
        }
    }

    // MARK: Navigation

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
        // Coming up out of a folder selects it, so the user sees where they came from.
        state.selection = Paths.parent(of: previous) == location ? [Paths.lastComponent(of: previous)] : []
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
                onChange?()
            }
            return false
        default:
            // Files and packages will open in their app (#8).
            return false
        }
    }

    // MARK: Loading

    /// Reads the side's folder, then filters and sorts it, all off the main thread.
    private func load(_ side: Side) {
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
        state.entriesLocation = location
        switch result {
        case let .success((all, visible)):
            state.allEntries = all
            state.visibleEntries = visible
            state.status = .loaded
            // Keep only selected names that still exist.
            let visibleNames = Set(visible.map(\.entry.name))
            state.selection.formIntersection(visibleNames)
        case let .failure(error):
            state.allEntries = []
            state.visibleEntries = []
            state.selection = []
            state.status = .failed(Self.message(for: error, location: location))
        }
        state.entriesVersion += 1
        sides[side] = state
        pendingWork[side] = nil
        onChange?()
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
