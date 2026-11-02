import BlitterCore
import Foundation

/// An item's git state (#22, #35), shown as its color. Untracked and ignored items have none.
public enum GitState: Equatable, Sendable {
    /// Tracked and unchanged; for a working copy's root: no tracked changes, in step upstream.
    case clean
    /// A tracked file that changed, or a folder with such a file below it.
    case modified
    /// Nothing to commit, but commits ahead of or behind the upstream.
    case aheadOrBehind

    public var role: ThemeRole {
        switch self {
        case .clean: .gitClean
        case .modified: .gitModified
        case .aheadOrBehind: .gitAheadOrBehind
        }
    }
}

/// An item's git status in words, for the Git column (#25); its color is `state`.
public enum GitItemStatus: Equatable, Sendable {
    /// Tracked and unchanged (a folder: something tracked in it, no tracked change below it).
    case unchanged
    /// A tracked change: the file, or something below the folder.
    case modified
    case untracked
    case ignored
    /// A working copy's root with nothing to commit, but commits ahead of or behind upstream.
    case aheadOrBehind(ahead: Int, behind: Int)

    /// The color: untracked and ignored items have none (#35).
    public var state: GitState? {
        switch self {
        case .unchanged: .clean
        case .modified: .modified
        case .aheadOrBehind: .aheadOrBehind
        case .untracked, .ignored: nil
        }
    }
}

/// What the model asks of git; the real one runs git, tests use their own.
public struct GitAccess: Sendable {
    public var repositoryRoot: @Sendable (_ containing: String) -> String?
    public var isRepositoryRoot: @Sendable (String) -> Bool
    /// The status, or nil if it cannot be read; gives up when `cancelled` is set.
    public var status: @Sendable (_ root: String, _ cancelled: CancellationFlag) -> GitRepoStatus?

    public init(repositoryRoot: @escaping @Sendable (String) -> String?,
                isRepositoryRoot: @escaping @Sendable (String) -> Bool,
                status: @escaping @Sendable (String, CancellationFlag) -> GitRepoStatus?)
    {
        self.repositoryRoot = repositoryRoot
        self.isRepositoryRoot = isRepositoryRoot
        self.status = status
    }

    /// Nothing at all without a real git (no colors, and never the "install the developer tools"
    /// prompt `/usr/bin/git` would show). Every check, finding git included, runs where these are
    /// called: on a background task.
    public static let real = GitAccess(
        repositoryRoot: { Git.executable == nil ? nil : Git.repositoryRoot(containing: $0) },
        isRepositoryRoot: { Git.executable != nil && Git.isLocal($0) && Git.isRepositoryRoot($0) },
        status: { Git.status(of: $0, cancelled: $1) }
    )
}

/// A working copy's status with what the views ask for precomputed: which folders contain changes.
struct KnownRepository: Sendable {
    let status: GitRepoStatus
    let checked: Date
    /// Tracked files that changed, relative to the root.
    let changedFiles: Set<String>
    /// Every folder (relative, "" for the root) with a tracked change at or below it.
    let changedFolders: Set<String>
    /// Untracked and ignored items as git lists them: files, and folders ending in "/".
    let untracked: Set<String>
    let ignored: Set<String>

    init(_ status: GitRepoStatus, checked: Date) {
        self.status = status
        self.checked = checked
        changedFiles = Set(status.changed)
        var folders: Set<String> = []
        for path in status.changed {
            var folder = path
            while let slash = folder.lastIndex(of: "/") {
                folder = String(folder[..<slash])
                guard folders.insert(folder).inserted else {
                    break // its ancestors are in already
                }
            }
            folders.insert("")
        }
        changedFolders = folders
        untracked = Set(status.untracked)
        ignored = Set(status.ignored)
    }

    /// The root: modified only for tracked changes (untracked files do not count, #35).
    var rootStatus: GitItemStatus {
        if !status.changed.isEmpty {
            return .modified
        }
        return status.ahead + status.behind > 0 ? .aheadOrBehind(ahead: status.ahead, behind: status.behind)
            : .unchanged
    }

    /// An item inside the working copy, by its path relative to the root.
    func status(of relative: String, isFolder: Bool) -> GitItemStatus? {
        if relative == ".git" || relative.hasPrefix(".git/") {
            return nil
        }
        // A submodule with a tracked change is listed as a changed path itself.
        if changedFiles.contains(relative) || (isFolder && changedFolders.contains(relative)) {
            return .modified
        }
        // Unchanged only with something tracked in it: not a folder holding just ignored files,
        // an empty one, or an untracked one.
        if isFolder, status.trackedFolders.contains(relative) {
            return .unchanged
        }
        // Untracked or ignored itself, or inside a folder that is.
        var listed = isFolder ? relative + "/" : relative
        while true {
            if untracked.contains(listed) {
                return .untracked
            }
            if ignored.contains(listed) {
                return .ignored
            }
            guard let slash = listed.dropLast().lastIndex(of: "/") else {
                break
            }
            listed = String(listed[...slash])
        }
        return isFolder ? nil : .unchanged
    }
}

extension Workspace {
    public func gitState(ofFolder path: String) -> GitState? {
        gitState(of: path, isFolder: true)
    }

    /// The git state (color) of a file or folder: see `gitStatus`.
    public func gitState(of path: String, isFolder: Bool) -> GitState? {
        gitStatus(of: path, isFolder: isFolder)?.state
    }

    /// The git status of a file or folder: a working copy's root shows the repository's status;
    /// inside one, tracked changes are modified, other tracked items unchanged, and untracked
    /// and ignored items say so (#35, #25). Outside working copies, or with git off: none.
    public func gitStatus(of path: String, isFolder: Bool) -> GitItemStatus? {
        guard settings.gitColors else {
            return nil
        }
        var root = path
        while true {
            if let repository = gitRepositories[root] {
                if root == path {
                    return repository.rootStatus
                }
                let relative = String(path.dropFirst(root == "/" ? 1 : root.count + 1))
                return repository.status(of: relative, isFolder: isFolder)
            }
            guard root != "/", let parent = Paths.parent(of: root) else {
                return nil
            }
            root = parent
        }
    }

    /// What follows every listing: a folder action chosen while it was read (#20), and git (#22).
    func listingArrived(_ side: Side) {
        runPendingAction(on: side)
        updateGit(side)
    }

    /// Finds the working copy the side is in and those among its folders, and reads their status
    /// in the background: after every listing, and every `gitRefreshInterval` while the app runs
    /// (changes deep inside a working copy reach no watched folder). The one the side is in is
    /// always read again; the others when their status is older than `gitRefreshInterval`. Known
    /// working copies that are no longer one are forgotten. A newer call cancels the older one,
    /// git process included.
    /// `periodic`: the regular re-read leaves a scan that is still running alone, so a slow one
    /// still finishes; a new listing replaces it.
    func updateGit(_ side: Side, periodic: Bool = false) {
        guard settings.gitColors, let state = sides[side], state.status == .loaded,
              !(periodic && gitWork[side] != nil)
        else {
            return
        }
        gitWork[side]?.cancel()
        startGitPolling()
        let location = state.entriesLocation
        let folders = state.visibleEntries.filter { $0.entry.kind == .directory }.map {
            Paths.appending($0.entry.name, to: location)
        }
        let now = Date()
        let known = Set(gitRepositories.keys)
        let fresh = Set(gitRepositories.filter { now.timeIntervalSince($0.value.checked) < gitRefreshInterval }.keys)
        let access = gitAccess
        gitWork[side] = Task { [weak self] in
            let cancelled = CancellationFlag()
            let scan = GitScan(location: location, folders: folders, known: known, fresh: fresh)
            let worker = Task.detached(priority: .utility) {
                Self.readRepositories(scan, access: access, cancelled: cancelled)
            }
            let results = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                cancelled.set() // stops the git process too
                worker.cancel()
            }
            guard !Task.isCancelled, let self else {
                return
            }
            gitWork[side] = nil
            merge(results)
        }
    }

    /// Off the main actor: discovery, git, and the changed folders of each status. A root mapped
    /// to nil is forgotten (no longer a working copy, or git failed).
    private nonisolated static func readRepositories(_ scan: GitScan, access: GitAccess,
                                                     cancelled: CancellationFlag) -> [String: KnownRepository?]
    {
        let (location, folders, known, fresh) = (scan.location, scan.folders, scan.known, scan.fresh)
        var results: [String: KnownRepository?] = [:]
        func read(_ root: String) {
            let status = access.status(root, cancelled)
            if !cancelled.isSet {
                results.updateValue(status.map { KnownRepository($0, checked: Date()) }, forKey: root)
            }
        }
        let enclosing = access.repositoryRoot(location)
        // A working copy known to contain the side's folder that is no longer one. Being no longer
        // the nearest one proves nothing (the side may be in a submodule): it is checked again.
        for root in known where root != enclosing && (location == root || location.hasPrefix(root + "/")) {
            if !access.isRepositoryRoot(root) {
                results.updateValue(nil, forKey: root)
            }
        }
        if let enclosing {
            read(enclosing)
        }
        for folder in folders where folder != enclosing && !cancelled.isSet {
            if access.isRepositoryRoot(folder) {
                if !fresh.contains(folder) {
                    read(folder)
                }
            } else if known.contains(folder) {
                results.updateValue(nil, forKey: folder) // its .git is gone
            }
        }
        return results
    }

    private func merge(_ results: [String: KnownRepository?]) {
        var changed = false
        for (root, repository) in results {
            changed = changed || repository?.status != gitRepositories[root]?.status
            gitRepositories[root] = repository
        }
        if changed {
            gitVersion += 1
            notifyChange()
        }
    }

    /// While git colors are on: both sides' working copies are read again regularly.
    private func startGitPolling() {
        guard gitPolling == nil else {
            return
        }
        let interval = gitRefreshInterval
        gitPolling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else {
                    return
                }
                for side in Side.allCases {
                    updateGit(side, periodic: true)
                }
            }
        }
    }

    func stopGit() {
        for task in gitWork.values {
            task.cancel()
        }
        gitWork = [:]
        gitPolling?.cancel()
        gitPolling = nil
    }
}

/// What one git scan of a side looks at: its folder, the folders shown in it, the working copies
/// known so far, and those of them read recently enough.
struct GitScan: Sendable {
    let location: String
    let folders: [String]
    let known: Set<String>
    let fresh: Set<String>
}
