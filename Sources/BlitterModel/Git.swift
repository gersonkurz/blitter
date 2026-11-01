import BlitterCore
import Foundation

/// A folder's git state (#22), shown as its color.
public enum GitState: Equatable, Sendable {
    /// A working copy with nothing to commit and in step with its upstream.
    case clean
    /// Changed or untracked files: in the working copy, or below this folder inside one.
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
    /// Every folder (relative to the root, "" for the root) with a change at or below it.
    let changedFolders: Set<String>

    init(_ status: GitRepoStatus, checked: Date) {
        self.status = status
        self.checked = checked
        var folders: Set<String> = []
        for path in status.changed {
            var folder = path.hasSuffix("/") ? String(path.dropLast()) : path
            // An untracked folder ("dir/") contains changes itself; a file's folder does.
            if !path.hasSuffix("/"), let slash = folder.lastIndex(of: "/") {
                folder = String(folder[..<slash])
            } else if !path.hasSuffix("/") {
                folder = ""
            }
            while !folders.contains(folder) {
                folders.insert(folder)
                guard let slash = folder.lastIndex(of: "/") else {
                    folders.insert("")
                    break
                }
                folder = String(folder[..<slash])
            }
        }
        changedFolders = folders
    }

    var rootState: GitState {
        if !status.changed.isEmpty {
            return .modified
        }
        return status.ahead + status.behind > 0 ? .aheadOrBehind : .clean
    }
}

extension Workspace {
    /// The git state of a folder: a working copy's root shows the repository's state, a folder
    /// inside one shows "modified" if it contains changes; anything else has none.
    public func gitState(ofFolder path: String) -> GitState? {
        guard settings.gitColors else {
            return nil
        }
        var root = path
        while true {
            if let repository = gitRepositories[root] {
                if root == path {
                    return repository.rootState
                }
                let relative = String(path.dropFirst(root == "/" ? 1 : root.count + 1))
                return repository.changedFolders.contains(relative) ? .modified : nil
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
