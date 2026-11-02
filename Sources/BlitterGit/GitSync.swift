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
    /// The operation running now, and its job.
    public private(set) var running: (operation: Operation, job: Int)?
    public private(set) var outcome: Outcome?
    /// The running or last operation's output.
    public private(set) var output = ""
    public var onChange: (() -> Void)?

    private let workspace: Workspace
    private let access: GitSyncAccess
    private var statusWork: Task<Void, Never>?
    private var watching: Task<Void, Never>?

    public init(workspace: Workspace, path: String, access: GitSyncAccess = .real) {
        self.workspace = workspace
        self.access = access
        root = workspace.workingCopyRoot(containing: path)
        if root == nil {
            problem = "“\(path)” is not in a git working copy."
        }
        refresh()
    }

    /// Whether anything is still running (tests wait for it).
    public var isBusy: Bool {
        statusWork != nil || running != nil
    }

    public func perform(_ command: Command) {
        switch command {
        case let .run(operation): run(operation)
        case .cancel: running.map { workspace.perform(.cancelJob($0.job)) }
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
        guard let root, running == nil else {
            return
        }
        guard let git = access.git else {
            problem = "No git was found (install the Xcode command line tools, or git from Homebrew)."
            onChange?()
            return
        }
        let arguments = [git] + operation.arguments
        let known = Set(workspace.jobs.map(\.id))
        workspace.perform(.runCommand(arguments, folder: root))
        guard let job = workspace.jobs.last(where: { !known.contains($0.id) && $0.operation == .command(
            arguments,
            folder: root
        ) })
        else {
            return
        }
        problem = nil
        outcome = nil
        output = ""
        running = (operation, job.id)
        onChange?()
        watch(job.id)
    }

    /// Follows the job's output while it runs (the jobs strip shows its progress too); its end,
    /// last output included, comes from the workspace, as a job that succeeded leaves the list
    /// at once.
    private func watch(_ id: Int) {
        workspace.whenJobDone(id) { [weak self] job in
            guard let self, let running, running.job == id else {
                return
            }
            output = job.progress.output
            let outcome: Outcome = switch job.state {
            case .cancelled: .cancelled(running.operation)
            default: job.errors.first.map { .failed(running.operation, $0.message) } ?? .succeeded(running.operation)
            }
            finish(running.operation, outcome: outcome)
        }
        watching = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let running, running.job == id else {
                    return
                }
                if let job = workspace.jobs.first(where: { $0.id == id }), job.progress.output != output {
                    output = job.progress.output
                    onChange?()
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func finish(_: Operation, outcome: Outcome) {
        running = nil
        self.outcome = outcome
        onChange?()
        refresh()
    }
}
