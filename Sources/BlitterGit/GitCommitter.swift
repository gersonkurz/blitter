import BlitterCore
import BlitterModel
import Foundation

/// What Git Commit asks of git; the real one runs it, tests use their own.
public struct GitCommitAccess: Sendable {
    public var changes: @Sendable (_ root: String, _ cancelled: CancellationFlag) -> GitWorkingChanges?
    public var messages: @Sendable (_ root: String, _ cancelled: CancellationFlag) -> [String]?
    /// A file's contents at a revision, nil if it cannot be read.
    public var contents: @Sendable (_ root: String, _ path: String, _ revision: String,
                                    _ cancelled: CancellationFlag) -> Data?
    /// The git to run: a real one, never `/usr/bin/git` (it only offers to install the tools).
    public var git: String?

    public static let real = GitCommitAccess(
        changes: { Git.workingChanges(of: $0, cancelled: $1) },
        messages: { Git.recentMessages(of: $0, cancelled: $1) },
        contents: { Git.contents(of: $1, at: $2, in: $0, cancelled: $3) },
        git: Git.executable
    )

    public init(changes: @escaping @Sendable (String, CancellationFlag) -> GitWorkingChanges?,
                messages: @escaping @Sendable (String, CancellationFlag) -> [String]?,
                contents: @escaping @Sendable (String, String, String, CancellationFlag) -> Data?, git: String?)
    {
        self.changes = changes
        self.messages = messages
        self.contents = contents
        self.git = git
    }
}

/// Git Commit (#44): the working copy's changed and untracked files, each checked to go into the
/// commit (the staged ones at first), a message, and Commit or Commit & Push. A commit holds
/// exactly the checked files as they are on disk; other staged files stay staged. It runs as
/// jobs: `git add` for checked untracked files, `git commit`, then `git push` (never forced).
@MainActor
public final class GitCommitter {
    public enum Step: Equatable, Sendable {
        case add
        case commit
        case push

        public var title: String {
            switch self {
            case .add: "Adding the new files"
            case .commit: "Commit"
            case .push: "Push"
            }
        }
    }

    public enum Command: Equatable, Sendable {
        /// Check or uncheck files (by path) for the commit.
        case check([String], Bool)
        case checkAll(Bool)
        /// Commit the checked files with the message, then push if asked.
        case commit(message: String, push: Bool)
        /// Show a file's last committed version beside the one on disk, in the diff tool.
        case compare(String)
        /// Cancel the running step's job.
        case cancel
        /// Read the changes again.
        case refresh
    }

    public enum Outcome: Equatable, Sendable {
        case committed(pushed: Bool)
        case failed(Step, String)
        case cancelled(Step)
    }

    public let root: String?
    /// Nil while it is read (and if it could not be).
    public private(set) var changes: GitWorkingChanges?
    public private(set) var checked: Set<String> = []
    /// Earlier commit messages, newest first, to pick from.
    public private(set) var recentMessages: [String] = []
    /// Why the changes could not be read, a commit not started, or a file not compared.
    public private(set) var problem: String?
    public private(set) var running: Step?
    public private(set) var outcome: Outcome?
    public var onChange: (() -> Void)?

    private let workspace: Workspace
    private let access: GitCommitAccess
    private let commands: CommandSequence
    private let work = BackgroundWork()
    /// The steps of the running commit.
    private var steps: [Step] = []
    /// Cancel was chosen while the commit was being prepared.
    private var cancelRequested = false
    /// The paths listed before, so a refresh keeps their checks and checks only new staged files.
    private var listed: Set<String> = []

    public init(workspace: Workspace, path: String, access: GitCommitAccess = .real) {
        self.workspace = workspace
        self.access = access
        root = workspace.workingCopyRoot(containing: path)
        commands = CommandSequence(workspace: workspace, folder: root ?? "/")
        commands.onChange = { [weak self] in
            self?.stepChanged()
            self?.onChange?()
        }
        if root == nil {
            problem = "“\(path)” is not in a git working copy."
        }
        refresh()
    }

    /// The running or last commit's output (all its steps).
    public var output: String {
        commands.output
    }

    /// Whether anything is still running (tests wait for it).
    public var isBusy: Bool {
        !work.isEmpty || running != nil
    }

    /// Whether `.commit` with this message would start now.
    public func canCommit(message: String) -> Bool {
        running == nil && changes != nil && !checked.isEmpty
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func perform(_ command: Command) {
        switch command {
        case let .check(paths, include): check(paths, include)
        case let .checkAll(include): check(changes?.files.map(\.path) ?? [], include)
        case let .commit(message, push): commit(message, push: push)
        case let .compare(path): compare(path)
        case .cancel: cancel()
        case .refresh: refresh()
        }
    }

    private func check(_ paths: [String], _ include: Bool) {
        guard running == nil else {
            return
        }
        let present = Set(changes?.files.map(\.path) ?? [])
        for path in paths where present.contains(path) {
            if include {
                checked.insert(path)
            } else {
                checked.remove(path)
            }
        }
        onChange?()
    }

    // MARK: Reading

    private func refresh() {
        guard let root else {
            return
        }
        let access = access
        run("changes") { cancelled in
            (access.changes(root, cancelled), cancelled.isSet ? nil : access.messages(root, cancelled))
        } then: { [weak self] changes, messages in
            self?.apply(changes, messages: messages)
        }
    }

    private func apply(_ changes: GitWorkingChanges?, messages: [String]?) {
        self.changes = changes
        recentMessages = messages ?? recentMessages
        guard let files = changes?.files else {
            problem = "The working copy's changes could not be read."
            return
        }
        // A file listed before keeps its check; a new one is checked if it is staged.
        checked = Set(files.filter { listed.contains($0.path) ? checked.contains($0.path) : $0.staged != nil }
            .map(\.path))
        listed = Set(files.map(\.path))
    }

    // MARK: Committing

    /// Prepares the commit's files in the background (it counts as running meanwhile), then runs
    /// its steps. The steps go on, and their files are removed at the end, even if the window
    /// closes before: the job queue holds on to the running steps.
    private func commit(_ message: String, push: Bool) {
        guard let root, canCommit(message: message), let files = changes?.files else {
            return
        }
        guard let git = access.git else {
            problem = "No git was found (install the Xcode command line tools, or git from Homebrew)."
            onChange?()
            return
        }
        let chosen = files.filter { checked.contains($0.path) }
        problem = nil
        outcome = nil
        cancelRequested = false
        running = chosen.contains(where: \.isUntracked) ? .add : .commit
        onChange?()
        Task { // holds on to the committer until the steps run (or never will)
            let plan = await Task.detached(priority: .userInitiated) {
                GitCommitPlan.prepare(message: message, chosen: chosen, root: root, git: git, push: push)
            }.value
            start(plan, pushed: push)
        }
    }

    private func start(_ prepared: Result<GitCommitPlan, GitFailure>, pushed: Bool) {
        let plan: GitCommitPlan
        switch prepared {
        case let .success(prepared): plan = prepared
        case let .failure(failure):
            running = nil
            problem = failure.message
            onChange?()
            return
        }
        guard !cancelRequested else {
            plan.discard()
            finishWithout(.cancelled(plan.steps[0].step))
            return
        }
        steps = plan.steps.map(\.step)
        let started = commands.start(plan.steps.map(\.arguments)) { [weak self] ending in
            plan.discard()
            self?.finish(ending, pushed: pushed)
        }
        if !started {
            plan.discard()
            finishWithout(.failed(plan.steps[0].step, "It could not be started."))
        }
    }

    private func cancel() {
        if commands.running != nil {
            commands.cancel()
        } else if running != nil {
            cancelRequested = true // still preparing: nothing is started then
        }
    }

    private func finish(_ ending: CommandSequence.Ending, pushed: Bool) {
        let outcome: Outcome = switch ending {
        case .succeeded: .committed(pushed: pushed)
        case let .failed(step, message): .failed(steps[step], message)
        case let .cancelled(step): .cancelled(steps[step])
        }
        finishWithout(outcome)
    }

    private func finishWithout(_ outcome: Outcome) {
        running = nil
        self.outcome = outcome
        onChange?()
        refresh()
    }

    /// Keeps the running step up to date as the steps go by.
    private func stepChanged() {
        if running != nil, let step = commands.running?.step {
            running = steps[step]
        }
    }

    // MARK: Comparing

    /// The last committed version (none for a new file, or before the first commit) beside the
    /// file on disk (an empty one if it is not there); the one on disk is shown as it is, so it can be
    /// edited in the diff tool.
    private func compare(_ path: String) {
        guard let root, let changes, let file = changes.files.first(where: { $0.path == path }) else {
            return
        }
        problem = nil
        let (access, hasCommits) = (access, changes.hasCommits)
        run("compare-" + path) { cancelled in
            Self.versions(of: file, root: root, hasCommits: hasCommits, access: access, cancelled: cancelled)
        } then: { [weak self] result in
            switch result {
            case let .success(files): self?.workspace.perform(.compare(left: files.before, right: files.after))
            case let .failure(failure): self?.problem = failure.message
            case nil: break // cancelled
            }
        }
    }

    /// Off the main actor. Nil when cancelled.
    private nonisolated static func versions(
        of file: GitFileChange, root: String, hasCommits: Bool, access: GitCommitAccess, cancelled: CancellationFlag
    ) -> Result<(before: String, after: String), GitFailure>? {
        let name = (file.path as NSString).lastPathComponent
        // Not in HEAD: before the first commit, added, or untracked with nothing staged (an
        // untracked file whose deletion is staged, `git rm --cached`, is in HEAD).
        let isNew = !hasCommits || file.staged == "A" || file.staged == nil && file.isUntracked
        let onDisk = GitCommitPlan.isOnDisk(file.path, in: root) // the disk says, not the letters
        let folder = CompareCopies.newFolder()
        var committed = Data()
        if !isNew {
            let old = file.oldPath ?? file.path
            let data = access.contents(root, old, "HEAD", cancelled)
            if cancelled.isSet {
                return nil
            }
            guard let data else {
                return .failure(GitFailure(message: "“\(old)” could not be read at HEAD."))
            }
            committed = data
        }
        return CompareCopies.write(committed, name: name, label: "HEAD", in: folder).flatMap { before in
            onDisk ? .success((before, root + "/" + file.path))
                : CompareCopies.write(Data(), name: name, label: "deleted", in: folder).map { (before, $0) }
        }
    }

    /// Runs `body` in the background under `key`, then `apply` and tells the window.
    private func run<Result: Sendable>(_ key: String, _ body: @escaping @Sendable (CancellationFlag) -> Result,
                                       then apply: @escaping @MainActor (Result) -> Void)
    {
        work.run(key, body) { [weak self] result in
            apply(result)
            self?.onChange?()
        }
    }
}
