import BlitterCore
import Foundation

/// Going to folders: typed paths, the parent, back and forward, opening entries.
extension Workspace {
    /// A typed path. The path field shows a search as `search://…` (#48): that text is not a
    /// path, so it changes nothing (searches are typed in the Find panel), whether it is the
    /// side's own search entered again or one pasted from elsewhere.
    func navigate(_ side: Side, _ input: String) -> Bool {
        guard let state = sides[side], !input.hasPrefix(FindState.scheme), let path = Paths.resolve(
            input,
            relativeTo: state.location,
            home: home
        ) else {
            return false
        }
        return go(side, .path(path))
    }

    func goToParent(_ side: Side) -> Bool {
        guard let parent = sides[side].flatMap({ Paths.parent(of: $0.location) }) else {
            return false
        }
        return go(side, .path(parent))
    }

    enum Destination {
        case path(String)
        case back
        case forward

        func isPossible(from state: SideState) -> Bool {
            switch self {
            case .path: true
            case .back: !state.backStack.isEmpty
            case .forward: !state.forwardStack.isEmpty
            }
        }
    }

    /// Moves the side to another folder, records it in the history, starts reading it and reveals
    /// it in the tree, under `treeRoot` if given. The old listing stays visible until the new one
    /// arrives. Returns false if there is nowhere to go.
    @discardableResult
    func go(_ side: Side, _ destination: Destination, treeRoot: String? = nil) -> Bool {
        guard let current = sides[side], destination.isPossible(from: current) else {
            return false // nowhere to go: a search shown stays as it is (#48 review)
        }
        leaveFind(side) // any navigation ends a search, even to the folder it searched (#48)
        dropViewWork(side)
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
        Self.remember(location, in: &state)
        // Coming up out of a folder selects it once the parent's listing is there, so the user sees
        // where they came from. Until then the old rows are shown, with nothing selected.
        state.selection = []
        state.renameRequest = nil
        state.quickFilter = nil // it was for the folder we leave (#39)
        state.highlighted = []
        state.selectsFirstMatch = false
        state.fallsBackToHome = false
        state.pendingSelection = Paths.parent(of: previous) == location
            ? PendingSelection(folder: location, name: Paths.lastComponent(of: previous)) : nil
        state.pendingAction = nil
        sides[side] = state
        cancelPendingOpen(side)
        cancelHighlightSearch(side)
        load(side)
        revealInTree(side, preferredRoot: treeRoot)
        return true
    }

    /// The path field's recent folders: `location` first, each once, at most `maxRecentLocations`.
    private static func remember(_ location: String, in state: inout SideState) {
        state.recentLocations.removeAll { $0 == location }
        state.recentLocations.insert(location, at: 0)
        if state.recentLocations.count > maxRecentLocations {
            state.recentLocations.removeLast()
        }
    }

    /// A navigation the user asked for wins over a symbolic link still being checked.
    private func cancelPendingOpen(_ side: Side) {
        pendingOpen[side]?.cancel()
        pendingOpen[side] = nil
    }

    /// Opens a folder entry in this side. Returns true if the state changed now; a symbolic link
    /// is first checked in the background and opened only if it leads to a folder.
    func open(_ side: Side, _ name: String) -> Bool {
        guard let state = sides[side],
              let listed = state.listed(name)
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
                    system.open(path)
                    return
                }
                go(side, .path(path))
                notifyChange()
            }
            return false
        default:
            system.open(path) // a file or a package: its default app opens it
            return false
        }
    }
}
