import BlitterCore
import BlitterModel
import Foundation

/// What Git Sync asks of git and the disk; the real one reads them, tests use their own.
public struct GitSyncAccess: Sendable {
    /// The working copy's status (branch, upstream, ahead and behind), or nil.
    public var status: @Sendable (_ root: String, _ cancelled: CancellationFlag) -> GitRepoStatus?
    /// When it was last fetched, if ever (the time of its `FETCH_HEAD`).
    public var lastFetch: @Sendable (_ root: String, _ cancelled: CancellationFlag) -> Date?
    /// The git to run: a real one, never `/usr/bin/git` (it only offers to install the tools).
    public var git: String?

    public static let real = GitSyncAccess(
        status: { Git.status(of: $0, cancelled: $1) },
        lastFetch: { Git.lastFetch(of: $0, cancelled: $1) },
        git: Git.executable
    )

    public init(status: @escaping @Sendable (String, CancellationFlag) -> GitRepoStatus?,
                lastFetch: @escaping @Sendable (String, CancellationFlag) -> Date?, git: String?)
    {
        self.status = status
        self.lastFetch = lastFetch
        self.git = git
    }
}

/// Git Sync (#43): a working copy's branch and how it stands against its upstream, and Fetch,
/// Pull (rebase) and Push. Each runs as a job (in the jobs strip, with Cancel); its output
/// shows here as it comes. Never `--force`: a rejected push is shown, not retried.
@MainActor
public final class GitSync {
    public enum Operation: String, CaseIterable, Sendable {
        case fetch
        case pull
        case push

        public var title: String {
            switch self {
            case .fetch: "Fetch"
            case .pull: "Pull (rebase)"
            case .push: "Push"
            }
        }

        var arguments: [String] {
            switch self {
            case .fetch: ["fetch", "--prune"]
            case .pull: ["pull", "--rebase"]
            case .push: ["push"]
            }
        }
    }

    public enum Command: Equatable, Sendable {
        case run(Operation)
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

    public func perform(_ command: Command) {
        switch command {
        case let .run(operation): run(operation)
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
                // Both stop when the read is replaced; the second is not started then.
                let status = access.status(root, cancelled)
                return (status, cancelled.isSet ? nil : access.lastFetch(root, cancelled))
            }
            let (status, lastFetch) = await withTaskCancellationHandler {
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
            if status == nil, running == nil {
                problem = "The working copy's state could not be read."
            }
            onChange?()
        }
    }

    // MARK: Operations

    private func run(_ operation: Operation) {
        guard root != nil, running == nil else {
            return
        }
        guard let git = access.git else {
            problem = "No git was found (install the Xcode command line tools, or git from Homebrew)."
            onChange?()
            return
        }
        let started = commands.start([[git] + operation.arguments]) { [weak self] ending in
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
        onChange?()
        refresh()
    }
}
