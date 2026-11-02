import BlitterCore
import BlitterModel
import Foundation

/// What Git Sync asks of git and the disk; the real one reads them, tests use their own.
public struct GitSyncAccess: Sendable {
    /// The working copy's status (branch, upstream, ahead and behind), or nil.
    public var status: @Sendable (_ root: String, _ cancelled: CancellationFlag) -> GitRepoStatus?
    /// When it was last fetched, if ever (the time of its `FETCH_HEAD`).
    public var lastFetch: @Sendable (_ root: String, _ cancelled: CancellationFlag) -> Date?
    /// Whether a rebase is under way (#45).
    public var rebasing: @Sendable (_ root: String, _ cancelled: CancellationFlag) -> Bool
    /// The git to run: a real one, never `/usr/bin/git` (it only offers to install the tools).
    public var git: String?

    public static let real = GitSyncAccess(
        status: { Git.status(of: $0, cancelled: $1) },
        lastFetch: { Git.lastFetch(of: $0, cancelled: $1) },
        rebasing: { Git.isRebasing($0, cancelled: $1) },
        git: Git.executable
    )

    public init(status: @escaping @Sendable (String, CancellationFlag) -> GitRepoStatus?,
                lastFetch: @escaping @Sendable (String, CancellationFlag) -> Date?,
                rebasing: @escaping @Sendable (String, CancellationFlag) -> Bool = { _, _ in false }, git: String?)
    {
        self.status = status
        self.lastFetch = lastFetch
        self.rebasing = rebasing
        self.git = git
    }
}

/// Git Sync (#43): a working copy's branch and how it stands against its upstream, and Fetch,
/// Pull (rebase), Fetch & Rebase (#45) and Push. Each runs as jobs (in the jobs strip, with
/// Cancel); their output shows here as it comes. Never `--force`: a rejected push is shown, not
/// retried. A rebase that stopped on a conflict is shown as such: it can be aborted here, or
/// finished in the terminal; nothing else runs until then.
@MainActor
public final class GitSync {
    public enum Operation: String, CaseIterable, Sendable {
        case fetch
        case pull
        case fetchAndRebase
        case push
        case abortRebase

        /// The ones that bring the branch and its upstream together, in the window's order.
        public static let syncing: [Operation] = [.fetch, .pull, .fetchAndRebase, .push]

        public var title: String {
            switch self {
            case .fetch: "Fetch"
            case .pull: "Pull (rebase)"
            case .fetchAndRebase: "Fetch & Rebase"
            case .push: "Push"
            case .abortRebase: "Abort Rebase"
            }
        }

        /// git's arguments, one list per step: a step runs only if the one before succeeded.
        var steps: [[String]] {
            switch self {
            case .fetch: [["fetch", "--prune"]]
            case .pull: [["pull", "--rebase"]]
            case .fetchAndRebase: [["fetch", "--prune"], ["rebase", "@{upstream}"]]
            case .push: [["push"]]
            case .abortRebase: [["rebase", "--abort"]]
            }
        }
    }

    public enum Command: Equatable, Sendable {
        case run(Operation)
        /// Open the working copy with the terminal tool, to finish a rebase there (#45).
        case openTerminal
        /// Cancel the running operation's job.
        case cancel
        /// Read the status again.
        case refresh
    }

    /// How the last operation ended.
    public enum Outcome: Equatable, Sendable {
        case succeeded(Operation)
        case failed(Operation, String)
        case cancelled(Operation)
    }

    public let root: String?
    public private(set) var status: GitRepoStatus?
    public private(set) var lastFetch: Date?
    /// A rebase is under way, most likely stopped on a conflict (#45).
    public private(set) var isRebasing = false
    /// Why the status could not be read, or an operation not started.
    public private(set) var problem: String?
    /// The operation running now.
    public private(set) var running: Operation?
    public private(set) var outcome: Outcome?
    public var onChange: (() -> Void)?

    private let workspace: Workspace
    private let access: GitSyncAccess
    private let commands: CommandSequence
    private var statusWork: Task<Void, Never>?

    public init(workspace: Workspace, path: String, access: GitSyncAccess = .real) {
        self.workspace = workspace
        self.access = access
        root = workspace.workingCopyRoot(containing: path)
        commands = CommandSequence(workspace: workspace, folder: root ?? "/")
        if root == nil {
            problem = "“\(path)” is not in a git working copy."
        }
        commands.onChange = { [weak self] in self?.onChange?() }
        refresh()
    }

    /// The running or last operation's output.
    public var output: String {
        commands.output
    }

    /// Whether anything is still running (tests wait for it).
    public var isBusy: Bool {
        statusWork != nil || running != nil
    }

    /// Whether `.run(operation)` would start now: one at a time, and only on a state read
    /// after the last one ended (it may have left a rebase stopped, #45 review); during a rebase
    /// only Abort Rebase; Pull, Fetch & Rebase and Push need an upstream.
    public func canRun(_ operation: Operation) -> Bool {
        guard root != nil, running == nil, statusWork == nil else {
            return false
        }
        return switch operation {
        case .abortRebase: isRebasing
        case .fetch: !isRebasing
        case .pull, .fetchAndRebase, .push: !isRebasing && status?.upstream != nil
        }
    }

    public func perform(_ command: Command) {
        switch command {
        case let .run(operation): run(operation)
        case .openTerminal:
            if let root, let open = workspace.terminalCommand(for: root) {
                workspace.perform(open)
            }
        case .cancel: commands.cancel()
        case .refresh: refresh()
        }
    }

    // MARK: Status

    private func refresh() {
        guard let root else {
            return
        }
        statusWork?.cancel()
        let access = access
        statusWork = Task { [weak self] in
            let cancelled = CancellationFlag()
            let worker = Task.detached(priority: .userInitiated) {
                // All stop when the read is replaced; the later ones are not started then.
                let status = access.status(root, cancelled)
                let lastFetch = cancelled.isSet ? nil : access.lastFetch(root, cancelled)
                return (status, lastFetch, !cancelled.isSet && access.rebasing(root, cancelled))
            }
            let (status, lastFetch, rebasing) = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                cancelled.set()
            }
            guard !Task.isCancelled, let self else {
                return
            }
            statusWork = nil
            self.status = status
            self.lastFetch = lastFetch
            isRebasing = rebasing
            if status == nil, running == nil {
                problem = "The working copy's state could not be read."
            }
            onChange?()
        }
    }

    // MARK: Operations

    private func run(_ operation: Operation) {
        guard canRun(operation) else {
            return
        }
        guard let git = access.git else {
            problem = "No git was found (install the Xcode command line tools, or git from Homebrew)."
            onChange?()
            return
        }
        let started = commands.start(operation.steps.map { [git] + $0 }) { [weak self] ending in
            let outcome: Outcome = switch ending {
            case .succeeded: .succeeded(operation)
            case let .failed(_, message): .failed(operation, message)
            case .cancelled: .cancelled(operation)
            }
            self?.finish(outcome)
        }
        guard started else {
            return
        }
        problem = nil
        outcome = nil
        running = operation
        onChange?()
    }

    private func finish(_ outcome: Outcome) {
        running = nil
        self.outcome = outcome
        refresh() // first: nothing can start before the new state is read
        onChange?()
    }
}
