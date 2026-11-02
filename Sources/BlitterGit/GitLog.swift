import BlitterCore
import BlitterModel
import Foundation

/// What the Git Log asks of git; the real one runs it, tests use their own.
public struct GitHistoryAccess: Sendable {
    public var log: @Sendable (_ root: String, _ path: String?, _ cancelled: CancellationFlag) -> [GitCommit]?
    public var changes: @Sendable (_ root: String, _ commit: GitCommit, _ cancelled: CancellationFlag) -> [GitChange]?
    public var contents: @Sendable (_ root: String, _ path: String, _ revision: String,
                                    _ cancelled: CancellationFlag) -> Data?

    public static let real = GitHistoryAccess(
        log: { Git.log(of: $0, path: $1, cancelled: $2) },
        changes: { Git.changes(in: $0, commit: $1, cancelled: $2) },
        contents: { Git.contents(of: $1, at: $2, in: $0, cancelled: $3) }
    )

    public init(log: @escaping @Sendable (String, String?, CancellationFlag) -> [GitCommit]?,
                changes: @escaping @Sendable (String, GitCommit, CancellationFlag) -> [GitChange]?,
                contents: @escaping @Sendable (String, String, String, CancellationFlag) -> Data?)
    {
        self.log = log
        self.changes = changes
        self.contents = contents
    }
}

/// The Git Log (#42): the history of a working copy, or of a file or folder in it, a filter
/// over it, and the files the selected commit changed, each shown in the diff tool on request.
/// Everything git does runs in the background; a newer request cancels the older one. The
/// window renders this and changes it only through `perform`.
@MainActor
public final class GitLog {
    public enum Status: Equatable, Sendable {
        case loading
        /// `truncated`: the history is longer than what was read.
        case loaded(truncated: Bool)
        case failed(String)
    }

    public enum Command: Equatable, Sendable {
        /// Show only commits whose subject or author contains the text, or whose hash starts with it.
        case filter(String)
        /// Select a commit by hash (nil: none) and read the files it changed.
        case select(String?)
        /// Show a changed file of the selected commit, before and after, in the diff tool.
        case compare(GitChange)
    }

    /// How many commits are read, newest first.
    public static let limit = 20000

    public let path: String
    /// The working copy's top folder; nil if `path` is in none the workspace knows.
    public let root: String?
    public private(set) var status = Status.loading
    public private(set) var commits: [GitCommit] = []
    /// `commits` after the filter.
    public private(set) var shown: [GitCommit] = []
    public private(set) var filter = ""
    public private(set) var selected: GitCommit?
    /// The files `selected` changed; nil while they are read.
    public private(set) var changes: [GitChange]? = []
    /// Why the last comparison could not be shown, until the next one.
    public private(set) var problem: String?
    public var onChange: (() -> Void)?

    private let workspace: Workspace
    private let access: GitHistoryAccess
    private var work: [String: Task<Void, Never>] = [:]

    public init(workspace: Workspace, path: String, access: GitHistoryAccess = .real) {
        self.workspace = workspace
        self.path = path
        self.access = access
        root = workspace.workingCopyRoot(containing: path)
        load()
    }

    /// The part of `path` below the working copy's top folder; nil for the whole working copy.
    public var relativePath: String? {
        guard let root, path != root else {
            return nil
        }
        return String(path.dropFirst(root == "/" ? 1 : root.count + 1))
    }

    /// Whether anything is still running (tests wait for it).
    public var isBusy: Bool {
        !work.isEmpty
    }

    public func perform(_ command: Command) {
        switch command {
        case let .filter(text): setFilter(text)
        case let .select(hash): select(hash)
        case let .compare(change): compare(change)
        }
    }

    // MARK: Reading

    private func load() {
        guard let root else {
            status = .failed("“\(path)” is not in a git working copy.")
            return
        }
        let (access, relative) = (access, relativePath)
        run("log") { cancelled in
            access.log(root, relative, cancelled)
        } then: { [weak self] commits in
            guard let self else {
                return
            }
            guard let commits else {
                status = .failed("The history could not be read.")
                return
            }
            self.commits = commits
            status = .loaded(truncated: commits.count >= Self.limit)
            setFilter(filter, force: true)
        }
    }

    private func setFilter(_ text: String, force: Bool = false) {
        guard force || text != filter else {
            return
        }
        filter = text
        let commits = commits
        run("filter") { _ in
            Self.matching(commits, text)
        } then: { [weak self] shown in
            self?.shown = shown
        }
    }

    /// Off the main actor: a long history takes a moment to search.
    private nonisolated static func matching(_ commits: [GitCommit], _ text: String) -> [GitCommit] {
        let needle = text.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else {
            return commits
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let hash = needle.lowercased()
        return commits.filter {
            $0.subject.range(of: needle, options: options) != nil || $0.author
                .range(of: needle, options: options) != nil
                || $0.hash.hasPrefix(hash)
        }
    }

    private func select(_ hash: String?) {
        guard hash != selected?.hash else {
            return
        }
        selected = hash.flatMap { hash in commits.first { $0.hash == hash } }
        guard let root, let commit = selected else {
            work["changes"]?.cancel()
            work["changes"] = nil
            changes = []
            onChange?()
            return
        }
        changes = nil
        onChange?()
        let access = access
        run("changes") { cancelled in
            access.changes(root, commit, cancelled) ?? []
        } then: { [weak self] changes in
            self?.changes = changes
        }
    }

    // MARK: Comparing

    /// The file before and after the selected commit, written to temporary files, then shown in
    /// the diff tool. A side the commit says is not there (an added file before, a deleted one
    /// after) is an empty file; a side that should be there but cannot be read is a problem,
    /// never shown as empty (#42 review).
    private func compare(_ change: GitChange) {
        guard let root, let commit = selected else {
            return
        }
        problem = nil
        let (access, workspace) = (access, workspace)
        run("compare-" + change.path) { cancelled in
            Self.writeVersions(of: change, in: commit, root: root, access: access, cancelled: cancelled)
        } then: { [weak self] result in
            switch result {
            case let .success(files): workspace.perform(.compare(left: files.before, right: files.after))
            case let .failure(failure): self?.problem = failure.message
            case nil: break // cancelled
            }
        }
    }

    struct CompareFailure: Error {
        let message: String
    }

    /// Off the main actor. Each comparison gets a folder of its own,
    /// `<temporary>/Blitter-Git/<unique>/<short revision>/<file name>`: two files of the same
    /// name, or a later comparison, never write over files a diff tool still shows. Nil when
    /// cancelled (nothing more is read or written then).
    private nonisolated static func writeVersions(
        of change: GitChange, in commit: GitCommit, root: String, access: GitHistoryAccess, cancelled: CancellationFlag
    ) -> Result<(before: String, after: String), CompareFailure>? {
        let name = (change.path as NSString).lastPathComponent
        let base = NSTemporaryDirectory() + "Blitter-Git/" + UUID().uuidString
        let beforeIsAbsent = change.status == "A" || commit.parent == nil
        let afterIsAbsent = change.status == "D"
        func read(_ path: String, at revision: String?, absent: Bool) -> Result<Data, CompareFailure>? {
            guard !absent, let revision else {
                return .success(Data())
            }
            let data = access.contents(root, path, revision, cancelled)
            if cancelled.isSet {
                return nil
            }
            return data.map { .success($0) }
                ?? .failure(CompareFailure(message: "“\(path)” could not be read at \(revision.prefix(10))."))
        }
        func write(_ data: Data, revision: String) -> Result<String, CompareFailure> {
            let folder = base + "/" + String(revision.prefix(10))
            do {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: folder + "/" + name))
                return .success(folder + "/" + name)
            } catch {
                return .failure(CompareFailure(message: "A copy to compare could not be written: "
                        + error.localizedDescription))
            }
        }
        guard let before = read(change.oldPath ?? change.path, at: commit.parent, absent: beforeIsAbsent),
              let after = read(change.path, at: commit.hash, absent: afterIsAbsent), !cancelled.isSet
        else {
            return nil
        }
        return before.flatMap { before in
            after.flatMap { after in
                write(before, revision: commit.parent ?? "none").flatMap { left in
                    write(after, revision: commit.hash).map { right in (left, right) }
                }
            }
        }
    }

    // MARK: Background work

    /// Runs `body` off the main actor under `key` (a newer one cancels it), then `apply` on the
    /// main actor and tells the window.
    private func run<Result: Sendable>(_ key: String, _ body: @escaping @Sendable (CancellationFlag) -> Result,
                                       then apply: @escaping @MainActor (Result) -> Void)
    {
        work[key]?.cancel()
        work[key] = Task { [weak self] in
            let cancelled = CancellationFlag()
            let worker = Task.detached(priority: .userInitiated) { body(cancelled) }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                cancelled.set()
            }
            guard !Task.isCancelled, let self else {
                return
            }
            work[key] = nil
            apply(result)
            onChange?()
        }
    }
}
