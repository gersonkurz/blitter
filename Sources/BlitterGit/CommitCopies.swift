import BlitterCore
import Foundation
import Synchronization

/// A whole commit as two folders for the diff tool (#89): its changed files before and after,
/// each at its path in the working copy, as `git difftool --dir-diff` shows a commit.
enum CommitCopies {
    /// One file to read from git and where its copy goes.
    struct Read: Equatable {
        let path: String
        let revision: String
        let folder: String
    }

    /// The two folders, named by the short revisions ("none" before a first commit), and what to
    /// read into them: a renamed file under its old name before, an added one only after, a
    /// deleted one only before.
    struct Plan: Equatable {
        let before: String
        let after: String
        let reads: [Read]
    }

    /// Fails when two files of a side would be the same file on disk (#89 review): names that
    /// differ only in case or Unicode form are one name to the Mac's usual (APFS) volumes, and a
    /// file can be in the way of a folder of another file ("Doc" and "doc/a.txt").
    static func plan(_ changes: [GitChange], of commit: GitCommit, in folder: String) -> Result<Plan, GitFailure> {
        let before = folder + "/" + (commit.parent.map { String($0.prefix(10)) } ?? "none")
        let after = folder + "/" + String(commit.hash.prefix(10))
        var reads: [Read] = []
        for change in changes {
            if let parent = commit.parent, change.status != "A" {
                reads.append(Read(path: change.oldPath ?? change.path, revision: parent, folder: before))
            }
            if change.status != "D" {
                reads.append(Read(path: change.path, revision: commit.hash, folder: after))
            }
        }
        for side in [before, after] {
            if let clash = clash(in: reads.filter { $0.folder == side }.map(\.path)) {
                return .failure(GitFailure(message: "“\(clash.0)” and “\(clash.1)” would be the same file on this Mac, "
                        + "so the commit cannot be shown as two folders. Compare its files one by one."))
            }
        }
        return .success(Plan(before: before, after: after, reads: reads))
    }

    /// Two paths of one side that would land on the same file or folder, if any.
    static func clash(in paths: [String]) -> (String, String)? {
        func key(_ path: some StringProtocol) -> String {
            String(path).precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
        }
        var files: [String: String] = [:] // key → path
        var folders: [String: String] = [:] // key of a folder on the way → a path below it
        for path in paths {
            let parts = path.split(separator: "/")
            for count in 1 ..< max(parts.count, 1) {
                let folder = key(parts.prefix(count).joined(separator: "/"))
                if let file = files[folder] {
                    return (file, path)
                }
                folders[folder] = folders[folder] ?? path
            }
            let own = key(path)
            if let other = files[own] ?? folders[own] {
                return (other, path)
            }
            files[own] = path
        }
        return nil
    }

    /// Off the main actor: every planned file read and written, a few git processes at a time
    /// (a large commit is read in a fraction of the time, and the machine stays usable). The first
    /// file that cannot be read or written is the failure, and no more are started. Nil when
    /// cancelled.
    static func write(_ changes: [GitChange], of commit: GitCommit, root: String, access: GitHistoryAccess,
                      cancelled: CancellationFlag) -> Result<(before: String, after: String), GitFailure>?
    {
        let plan: Plan
        switch self.plan(changes, of: commit, in: CompareCopies.newFolder()) {
        case let .success(planned): plan = planned
        case let .failure(failure): return .failure(failure)
        }
        let failures = Mutex<[String]>([])
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 6
        for read in plan.reads {
            queue.addOperation {
                guard !cancelled.isSet, failures.withLock({ $0.isEmpty }) else {
                    return
                }
                if let failure = copy(read, root: root, access: access, cancelled: cancelled) {
                    failures.withLock { $0.append(failure) }
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        if cancelled.isSet {
            return nil
        }
        if let failure = failures.withLock({ $0.first }) {
            return .failure(GitFailure(message: failure))
        }
        for side in [plan.before, plan.after] { // a side with no files is an empty folder, not a missing one
            if case let .failure(failure) = CompareCopies.makeFolder(side) {
                return .failure(failure)
            }
        }
        return .success((plan.before, plan.after))
    }

    /// One file: why it failed, or nil (also when cancelled; the caller sees that).
    private static func copy(_ read: Read, root: String, access: GitHistoryAccess,
                             cancelled: CancellationFlag) -> String?
    {
        guard let data = access.contents(root, read.path, read.revision, cancelled) else {
            return cancelled.isSet ? nil : "“\(read.path)” could not be read at \(read.revision.prefix(10))."
        }
        if case let .failure(failure) = CompareCopies.write(data, at: read.path, in: read.folder) {
            return failure.message
        }
        return nil
    }
}
