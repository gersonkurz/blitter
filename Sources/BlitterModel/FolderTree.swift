import BlitterCore
import Foundation

/// The groups at the top of the folder tree.
public enum TreeSection: String, CaseIterable, Sendable {
    case favorites
    case volumes
    case cloud

    public var title: String {
        switch self {
        case .favorites: "Favorites"
        case .volumes: "Volumes"
        case .cloud: "Cloud"
        }
    }
}

/// A place at the top of the folder tree, e.g. Home, a mounted volume or a cloud drive.
public struct TreeRoot: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case home
        case desktop
        case documents
        case downloads
        case applications
        case volume(isRoot: Bool, isLocal: Bool)
        case cloud
    }

    public let section: TreeSection
    public let title: String
    public let path: String
    public let kind: Kind

    /// Unique even if two roots show the same folder.
    public var id: String {
        section.rawValue + ":" + path
    }
}

/// A folder as it appears under one root. The same folder can appear under several roots (Home and
/// the startup volume), and each appearance is expanded and selected on its own.
public struct TreeNodeID: Hashable, Sendable {
    public let root: String
    public let path: String

    public init(root: String, path: String) {
        self.root = root
        self.path = path
    }
}

public struct TreeFolder: Equatable, Sendable {
    public let name: String
    public let isHidden: Bool
}

/// Subfolders of a folder, as far as they have been read.
public enum TreeChildren: Equatable, Sendable {
    case loading
    case loaded([TreeFolder])
    case failed
}

/// One side's folder tree.
public struct FolderTreeState: Sendable {
    public internal(set) var expanded: Set<TreeNodeID> = []
    /// Subfolders by folder path, shared by every root that shows the folder. Unfiltered: use
    /// `Workspace.treeChildren(of:on:)` for what the tree shows.
    var children: [String: TreeChildren] = [:]
    /// Folders whose loaded subfolders may be out of date: they stopped being watched after they
    /// were read. They are read again before they are shown again.
    var stale: Set<String> = []
    /// The node of the side's folder, if a root contains it.
    public internal(set) var selection: TreeNodeID?
    /// Increases whenever what the tree shows changes, so the view rebuilds only then.
    public internal(set) var version = 0
}

enum TreeRoots {
    static func favorites(home: String) -> [TreeRoot] {
        [
            TreeRoot(section: .favorites, title: "Home", path: home, kind: .home),
            TreeRoot(section: .favorites, title: "Desktop", path: home + "/Desktop", kind: .desktop),
            TreeRoot(section: .favorites, title: "Documents", path: home + "/Documents", kind: .documents),
            TreeRoot(section: .favorites, title: "Downloads", path: home + "/Downloads", kind: .downloads),
            TreeRoot(section: .favorites, title: "Applications", path: "/Applications", kind: .applications),
        ]
    }

    static func volumes(_ volumes: [MountedVolume]) -> [TreeRoot] {
        volumes.map {
            TreeRoot(section: .volumes, title: $0.name, path: $0.path,
                     kind: .volume(isRoot: $0.isRoot, isLocal: $0.isLocal))
        }
    }

    /// The parts of the roots that need the disk, read independently of each other.
    enum Part: CaseIterable {
        case volumes
        case iCloudDrive
        case cloudStorage
    }

    static func iCloudDrive(home: String) -> String {
        home + "/Library/Mobile Documents/com~apple~CloudDocs"
    }

    static func cloudStorage(home: String) -> String {
        home + "/Library/CloudStorage"
    }

    /// Every provider folder in `~/Library/CloudStorage`, named "Provider (account)" from the
    /// folder name "Provider-account".
    static func cloud(storage: String, entries: [DirectoryEntry]) -> [TreeRoot] {
        entries.filter { $0.kind == .directory && !$0.isHidden }.map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { name in
                let parts = name.split(separator: "-", maxSplits: 1)
                let title = parts.count == 2 ? "\(parts[0]) (\(parts[1]))" : name
                return TreeRoot(section: .cloud, title: title, path: Paths.appending(name, to: storage), kind: .cloud)
            }
    }

    /// Plain folders only: files, packages such as apps, and symbolic links are left out.
    static func subfolders(of entries: [DirectoryEntry]) -> [TreeFolder] {
        var types = ContentTypes()
        return entries.filter { $0.kind == .directory && !types.classify($0).type.conforms(to: .package) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { TreeFolder(name: $0.name, isHidden: $0.isHidden) }
    }
}

extension Workspace {
    /// The subfolders the tree shows under `path`: hidden ones only while hidden files are shown.
    public func treeChildren(of path: String, on side: Side) -> TreeChildren? {
        guard let children = sides[side]?.tree.children[path] else {
            return nil
        }
        guard case let .loaded(folders) = children, !showsHiddenFiles else {
            return children
        }
        return .loaded(folders.filter { !$0.isHidden })
    }

    // MARK: Commands

    func expandTreeNode(_ side: Side, _ node: TreeNodeID) -> Bool {
        guard sides[side]?.tree.expanded.insert(node).inserted == true else {
            return false
        }
        // Subfolders read while the folder was collapsed (and so not watched) may be out of date.
        loadTreeChildren(side, node.path, again: sides[side]?.tree.stale.contains(node.path) == true)
        sides[side]?.tree.version += 1
        return true
    }

    func collapseTreeNode(_ side: Side, _ node: TreeNodeID) -> Bool {
        guard var tree = sides[side]?.tree, tree.expanded.remove(node) != nil else {
            return false
        }
        // Nobody waits for a read of this folder any more: stop it, and read it again next time.
        if !tree.expanded.contains(where: { $0.path == node.path }), tree.children[node.path] == .loading {
            treeWork[side]?[node.path]?.cancel()
            treeWork[side]?[node.path] = nil
            tree.children[node.path] = nil
        }
        tree.version += 1
        sides[side]?.tree = tree
        return true
    }

    func selectTreeNode(_ side: Side, _ node: TreeNodeID) -> Bool {
        guard let state = sides[side], treeRoots.contains(where: { $0.id == node.root }) else {
            return false
        }
        if node.path == state.location {
            guard state.tree.selection != node else {
                return false
            }
            sides[side]?.tree.selection = node
            sides[side]?.tree.version += 1
            return true
        }
        return go(side, .path(node.path), treeRoot: node.root)
    }

    func refreshTreeRoots() -> Bool {
        loadTreeRoots()
        return false // the roots change when the read finishes
    }

    // MARK: Roots and reveal

    /// Reads volumes and cloud drives in the background, each part on its own. The favorites need
    /// no disk access and are there from the start.
    func loadTreeRoots() {
        let home = home
        let volumes = volumes
        let directoryCheck = directoryCheck
        let lister = lister
        readRoots(.volumes) {
            await TreeRoots.volumes(volumes())
        }
        readRoots(.iCloudDrive) {
            let path = TreeRoots.iCloudDrive(home: home)
            return await directoryCheck(path) ? [TreeRoot(section: .cloud, title: "iCloud Drive", path: path,
                                                          kind: .cloud)] : []
        }
        readRoots(.cloudStorage) {
            let storage = TreeRoots.cloudStorage(home: home)
            return await TreeRoots.cloud(storage: storage, entries: (try? lister(storage)) ?? [])
        }
    }

    /// Runs `read` off the main actor and publishes its roots when it finishes, unless a newer
    /// read of the same part replaced it.
    private func readRoots(_ part: TreeRoots.Part, _ read: @escaping @Sendable () async -> [TreeRoot]) {
        rootsWork[part]?.cancel()
        rootsWork[part] = Task { [weak self] in
            let roots = await read()
            guard !Task.isCancelled, let self else {
                return
            }
            rootsWork[part] = nil
            guard rootParts[part] != roots else {
                return
            }
            rootParts[part] = roots
            treeRoots = TreeRoots.favorites(home: home) + TreeRoots.Part.allCases.flatMap { rootParts[$0] ?? [] }
            for side in Side.allCases {
                revealInTree(side, preferredRoot: nil)
            }
            notifyChange()
        }
    }

    /// Selects the side's folder in the tree and expands the folders above it. The root is
    /// `preferredRoot` if it contains the folder, else the current selection's root if that does,
    /// else the most specific root that contains it.
    func revealInTree(_ side: Side, preferredRoot: String?) {
        guard var state = sides[side] else {
            return
        }
        let location = state.location
        let containing = treeRoots.filter { Paths.contains(location, in: $0.path) }
        let preferred = [preferredRoot, state.tree.selection?.root].compactMap(\.self)
        let root = preferred.lazy.compactMap { id in containing.first { $0.id == id } }.first
            ?? containing.max { $0.path.count < $1.path.count }
        guard let root else {
            if state.tree.selection != nil {
                sides[side]?.tree.selection = nil
                sides[side]?.tree.version += 1
            }
            return
        }
        var ancestors: [String] = []
        var path = location
        while path != root.path, let parent = Paths.parent(of: path) {
            ancestors.append(parent)
            path = parent
        }
        for ancestor in ancestors {
            state.tree.expanded.insert(TreeNodeID(root: root.id, path: ancestor))
        }
        state.tree.selection = TreeNodeID(root: root.id, path: location)
        state.tree.version += 1
        sides[side] = state
        for ancestor in ancestors.reversed() {
            loadTreeChildren(side, ancestor, again: sides[side]?.tree.stale.contains(ancestor) == true)
        }
    }

    /// Reads the subfolders of `path` for this side's tree unless they are loaded or being read.
    /// Each folder is read on its own, so a stalled volume holds up only its own nodes. With
    /// `again` the folder is read anyway: loaded subfolders stay visible until the new ones
    /// arrive, and a read still running is replaced, so an older result never wins.
    func loadTreeChildren(_ side: Side, _ path: String, again: Bool = false) {
        switch sides[side]?.tree.children[path] {
        case .loading?, .loaded?:
            guard again else {
                return
            }
        case .failed?, nil:
            sides[side]?.tree.children[path] = .loading
        }
        treeWork[side]?[path]?.cancel()
        // The folder is watched again by now (expanded folders are), so this read is current.
        sides[side]?.tree.stale.remove(path)
        let lister = lister
        treeWork[side, default: [:]][path] = Task { [weak self] in
            let children: TreeChildren
            do {
                children = try await .loaded(Self.readSubfolders(path, lister))
            } catch {
                children = .failed
            }
            guard !Task.isCancelled, let self else {
                return
            }
            treeWork[side]?[path] = nil
            guard sides[side]?.tree.children[path] != children else {
                return // read again after a change elsewhere in the folder: nothing to show
            }
            sides[side]?.tree.children[path] = children
            sides[side]?.tree.version += 1
            notifyChange()
        }
    }

    /// Nonisolated, so filtering and sorting run off the main actor.
    private nonisolated static func readSubfolders(_ path: String, _ lister: Lister) async throws -> [TreeFolder] {
        try await TreeRoots.subfolders(of: lister(path))
    }
}
