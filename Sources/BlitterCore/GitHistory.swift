import Foundation

/// A commit as the Git Log lists it (#42).
public struct GitCommit: Equatable, Sendable {
    public let hash: String
    /// The first parent, nil for a first commit: what the commit's changes are shown against.
    public let parent: String?
    public let author: String
    public let date: Date
    public let subject: String

    public init(hash: String, parent: String?, author: String, date: Date, subject: String) {
        self.hash = hash
        self.parent = parent
        self.author = author
        self.date = date
        self.subject = subject
    }
}

/// A file a commit changed: "A" added, "M" modified, "D" deleted, "R" renamed (from `oldPath`),
/// and git's other letters. Paths are relative to the working copy's top folder.
public struct GitChange: Equatable, Sendable {
    public let status: String
    public let path: String
    public let oldPath: String?

    public init(status: String, path: String, oldPath: String? = nil) {
        self.status = status
        self.path = path
        self.oldPath = oldPath
    }
}

/// A working copy's history (#42). Everything here runs git: call it off the main thread.
public extension Git {
    /// The latest `limit` commits, newest first, of the working copy or of `path` in it.
    static func log(of root: String, path: String? = nil, limit: Int = 20000, git: String? = executable,
                    timeout: TimeInterval = 30, cancelled: CancellationFlag = CancellationFlag()) -> [GitCommit]?
    {
        guard let git else {
            return nil
        }
        // A name is a name: "a*.txt" must not match "abc.txt" (#42 review).
        let arguments = ["--literal-pathspecs", "log", "-z", "--format=%H%x1f%P%x1f%an%x1f%at%x1f%s",
                         "-n", String(limit), "--"] + (path.map { [$0] } ?? [])
        return run(git, arguments, in: root, until: Date().addingTimeInterval(timeout), cancelled: cancelled)
            .map(parseLog)
    }

    /// The files `commit` changed against its first parent (a merge: what it brought in), or
    /// all its files for a first commit. Renames are found.
    static func changes(in root: String, commit: GitCommit, git: String? = executable, timeout: TimeInterval = 30,
                        cancelled: CancellationFlag = CancellationFlag()) -> [GitChange]?
    {
        guard let git else {
            return nil
        }
        let range = commit.parent.map { [$0, commit.hash] } ?? ["--root", commit.hash]
        let arguments = ["diff-tree", "--no-commit-id", "-r", "-z", "-M", "--name-status"] + range
        return run(git, arguments, in: root, until: Date().addingTimeInterval(timeout), cancelled: cancelled)
            .map(parseChanges)
    }

    /// A file's contents at a revision; nil if it was not there (added or deleted), git fails,
    /// or `cancelled` is set (git is stopped then).
    static func contents(of path: String, at revision: String, in root: String, git: String? = executable,
                         timeout: TimeInterval = 30, cancelled: CancellationFlag = CancellationFlag()) -> Data?
    {
        guard let git else {
            return nil
        }
        return run(git, ["show", revision + ":" + path], in: root, until: Date().addingTimeInterval(timeout),
                   cancelled: cancelled)
    }

    /// When the working copy was last fetched (#43): the time of its `FETCH_HEAD`, wherever git
    /// keeps it (a worktree's or a submodule's `.git` is a file pointing elsewhere). Nil if never.
    /// Stops git when `cancelled` is set.
    static func lastFetch(of root: String, git: String? = executable, timeout: TimeInterval = 10,
                          cancelled: CancellationFlag = CancellationFlag()) -> Date?
    {
        guard let git, !cancelled.isSet,
              let data = run(git, ["rev-parse", "--git-path", "FETCH_HEAD"], in: root,
                             until: Date().addingTimeInterval(timeout), cancelled: cancelled),
              let text = String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return nil
        }
        let path = text.hasPrefix("/") ? text : root + "/" + text
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Whether a rebase is under way (#45), stopped on a conflict or otherwise: git keeps its
    /// state in `rebase-merge` or `rebase-apply`, wherever the working copy's git folder is.
    /// False when git fails or is cancelled.
    static func isRebasing(_ root: String, git: String? = executable, timeout: TimeInterval = 10,
                           cancelled: CancellationFlag = CancellationFlag()) -> Bool
    {
        guard let git, !cancelled.isSet,
              let data = run(git, ["rev-parse", "--git-path", "rebase-merge", "--git-path", "rebase-apply"],
                             in: root, until: Date().addingTimeInterval(timeout), cancelled: cancelled),
              let text = String(bytes: data, encoding: .utf8)
        else {
            return false
        }
        return text.split(separator: "\n").contains { line in
            let path = line.hasPrefix("/") ? String(line) : root + "/" + line
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
        }
    }

    /// `git log -z --format=%H%x1f%P%x1f%an%x1f%at%x1f%s`: commits separated by NUL, fields
    /// by 0x1F. A subject cannot hold either.
    internal static func parseLog(_ data: Data) -> [GitCommit] {
        data.split(separator: 0).compactMap { record in
            // Lossy on purpose: a name that is not UTF-8 shows with "�", it is not dropped.
            let fields = record.split(separator: 0x1F, omittingEmptySubsequences: false).map {
                // swiftlint:disable:next optional_data_string_conversion
                String(decoding: $0, as: UTF8.self)
            }
            guard fields.count == 5, !fields[0].isEmpty, let seconds = TimeInterval(fields[3]) else {
                return nil
            }
            let parent = fields[1].split(separator: " ").first.map(String.init)
            return GitCommit(hash: fields[0], parent: parent, author: fields[2],
                             date: Date(timeIntervalSince1970: seconds), subject: fields[4])
        }
    }

    /// `git diff-tree -z --name-status`: a status, then its path, or two for a rename or copy
    /// ("R100", old, new), each NUL-terminated.
    internal static func parseChanges(_ data: Data) -> [GitChange] {
        // Lossy on purpose: a path that is not UTF-8 shows with "�", it is not dropped.
        // swiftlint:disable:next optional_data_string_conversion
        var fields = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }[...]
        var changes: [GitChange] = []
        while let status = fields.popFirst(), let first = fields.popFirst() {
            let letter = String(status.prefix(1))
            if letter == "R" || letter == "C" {
                guard let second = fields.popFirst() else {
                    break
                }
                changes.append(GitChange(status: letter, path: second, oldPath: first))
            } else {
                changes.append(GitChange(status: letter, path: first))
            }
        }
        return changes
    }
}
