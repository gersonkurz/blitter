import BlitterCore
import Foundation

/// Everything the user can do. The UI (and later the MCP server) changes state only through these.
public enum Command: Sendable {
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

    private var sides: [Side: SideState]
    private let lister: Lister
    /// The running load or re-sort per side. A new one cancels the previous one.
    private(set) var pendingWork: [Side: Task<Void, Never>] = [:]

    /// The source side. File operations go from here to the opposite side.
    public private(set) var activeSide: Side = .left
    public private(set) var showsHiddenFiles = false

    /// Called after every state change.
    public var onChange: (() -> Void)?

    public init(initialLocation: String = UserPaths.home, lister: @escaping Lister = listDirectory) {
        sides = [.left: SideState(location: initialLocation), .right: SideState(location: initialLocation)]
        self.lister = lister
        for side in Side.allCases {
            load(side)
        }
    }

    public func state(of side: Side) -> SideState {
        sides[side]! // swiftlint:disable:this force_unwrapping
    }

    public func perform(_ command: Command) {
        switch command {
        case .switchActiveSide:
            activeSide = activeSide.opposite
        case let .activate(side):
            guard activeSide != side else {
                return
            }
            activeSide = side
        case let .refresh(side):
            load(side)
        case let .sort(side, order):
            guard sides[side]?.sort != order else {
                return
            }
            sides[side]?.sort = order
            relist(side)
        case let .select(side, names):
            guard sides[side]?.selection != names else {
                return
            }
            sides[side]?.selection = names
        case .toggleHiddenFiles:
            showsHiddenFiles.toggle()
            for side in Side.allCases {
                relist(side)
            }
        }
        onChange?()
    }

    /// Reads the side's folder, then filters and sorts it, all off the main thread.
    private func load(_ side: Side) {
        guard let state = sides[side] else {
            return
        }
        sides[side]?.status = .loading
        let lister = lister
        let showHidden = showsHiddenFiles
        startWork(on: side) {
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
        startWork(on: side) {
            (state.allEntries, Listing.visibleEntries(state.allEntries, showHidden: showHidden, sort: state.sort))
        }
    }

    private func startWork(on side: Side,
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
            finish(side, with: result)
        }
    }

    private func finish(_ side: Side, with result: Result<([DirectoryEntry], [ListedEntry]), Error>) {
        guard var state = sides[side] else {
            return
        }
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
            state.status = .failed(Self.message(for: error, location: state.location))
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
