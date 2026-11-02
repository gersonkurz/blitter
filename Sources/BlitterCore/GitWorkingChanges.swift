import Foundation

/// A file with uncommitted changes, as Git Commit (#44) lists it. Paths are relative to the
/// working copy's top folder.
public struct GitFileChange: Equatable, Sendable {
    public let path: String
    /// A staged rename's or copy's original path (`staged` says which).
    public let oldPath: String?
    /// The change in the index ("A", "M", "D", "R", …), nil if nothing is staged.
    public let staged: Character?
    /// The change in the working tree against the index, nil if none; "?" untracked.
    public let unstaged: Character?

    public init(path: String, oldPath: String? = nil, staged: Character? = nil, unstaged: Character? = nil) {
        self.path = path
        self.oldPath = oldPath
        self.staged = staged
        self.unstaged = unstaged
    }

    public var isUntracked: Bool {
        unstaged == "?"
    }

    /// In conflict: both sides changed it during a merge or rebase ("U").
    public var isUnmerged: Bool {
        staged == "U" || unstaged == "U"
    }
}

/// What can be committed in a working copy (#44).
/// Each path is listed once: when git reports two records for one (a staged deletion of a file
/// that is back on disk, untracked: `git rm --cached`), they are one entry, its index letter
/// from the first, its working tree letter from the second.
public struct GitWorkingChanges: Equatable, Sendable {
    /// The branch checked out (nil: a detached HEAD) and its upstream.
    public var branch: String?
    public var upstream: String?
    /// Whether there is a commit yet; there is nothing to compare against before the first.
    public var hasCommits = true
    public var files: [GitFileChange] = []

    public init(branch: String? = nil, upstream: String? = nil, hasCommits: Bool = true, files: [GitFileChange] = []) {
        self.branch = branch
        self.upstream = upstream
        self.hasCommits = hasCommits
        self.files = files
    }
}

public extension Git {
    /// The working copy's uncommitted changes, every untracked file on its own (not a folder for
    /// a whole new folder), ignored ones left out. Nil if git fails or is cancelled.
    static func workingChanges(of root: String, git: String? = executable, timeout: TimeInterval = 30,
                               cancelled: CancellationFlag = CancellationFlag()) -> GitWorkingChanges?
    {
        guard let git else {
            return nil
        }
        let arguments = ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"]
        return run(git, arguments, in: root, until: Date().addingTimeInterval(timeout), cancelled: cancelled)
            .map(parseWorkingChanges)
    }

    /// The messages of the latest `limit` commits on HEAD, newest first, each once; none before
    /// the first commit. Nil if git fails or is cancelled.
    static func recentMessages(of root: String, limit: Int = 20, git: String? = executable,
                               timeout: TimeInterval = 10,
                               cancelled: CancellationFlag = CancellationFlag()) -> [String]?
    {
        guard let git else {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        // Before the first commit `git log` fails; that is no history, not a failure.
        guard run(git, ["rev-parse", "-q", "--verify", "HEAD"], in: root, until: deadline,
                  cancelled: cancelled) != nil
        else {
            return cancelled.isSet ? nil : []
        }
        return run(git, ["log", "-z", "--format=%B", "-n", String(limit)], in: root, until: deadline,
                   cancelled: cancelled).map(parseMessages)
    }

    internal static func parseWorkingChanges(_ data: Data) -> GitWorkingChanges {
        var status = GitRepoStatus()
        var hasCommits = true
        let records = records(data) { header in
            if header == "# branch.oid (initial)" {
                hasCommits = false
            }
            readHeader(header, into: &status)
        }
        var changes = GitWorkingChanges(branch: status.branch, upstream: status.upstream, hasCommits: hasCommits)
        var listed: [String: Int] = [:]
        for record in records where record.kind != "!" && !record.isUntrackedInSubmodule {
            func letter(_ character: Character?) -> Character? {
                character == "." ? nil : character
            }
            let file = switch record.kind {
            case "?": GitFileChange(path: record.path, unstaged: "?") // nothing of it is staged
            case "u": GitFileChange(path: record.path, staged: "U", unstaged: "U")
            default: GitFileChange(path: record.path, oldPath: record.oldPath, staged: letter(record.letters.first),
                                   unstaged: letter(record.letters.dropFirst().first))
            }
            if let index = listed[file.path] {
                let earlier = changes.files[index]
                changes.files[index] = GitFileChange(path: file.path, oldPath: earlier.oldPath ?? file.oldPath,
                                                     staged: earlier.staged ?? file.staged,
                                                     unstaged: file.unstaged ?? earlier.unstaged)
            } else {
                listed[file.path] = changes.files.count
                changes.files.append(file)
            }
        }
        return changes
    }

    /// `git log -z --format=%B`: messages separated by NUL, trimmed, each once.
    internal static func parseMessages(_ data: Data) -> [String] {
        var seen: Set<String> = []
        return data.split(separator: 0).compactMap { record in
            // Lossy on purpose: a message that is not UTF-8 shows with "�", it is not dropped.
            // swiftlint:disable:next optional_data_string_conversion
            let message = String(decoding: record, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty || !seen.insert(message).inserted ? nil : message
        }
    }
}
