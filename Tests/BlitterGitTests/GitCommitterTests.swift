@testable import BlitterCore
@testable import BlitterGit
@testable import BlitterModel
import Foundation
import Synchronization
import Testing

final class CommitTestWatcher: FolderWatching {
    func watch(_: Set<String>) {}
}

final class CommitTestLaunches: Sendable {
    let calls = Mutex<[[String]]>([])
}

/// Git Commit (#44), against a real git: what is listed and checked, what a commit holds, and
/// Commit & Push.
@MainActor
@Suite(.serialized)
struct GitCommitterTests {
    func committer(_ remote: GitTestRemote, _ clone: String, launches: CommitTestLaunches? = nil,
                   access: GitCommitAccess = .real) -> (GitCommitter, Workspace)
    {
        let workspace = Workspace(initialLocation: "/", home: "/", lister: { _ in [] }, directoryCheck: { _ in false },
                                  volumes: { [] }, watcher: { _ in CommitTestWatcher() })
        workspace.gitRepositories[remote.path(clone)] = KnownRepository(GitRepoStatus(), checked: Date())
        workspace.findDiffTool = { DiffTool(["tool", "{left}", "{right}"]) }
        workspace.launchTool = { arguments, _ in launches?.calls.withLock { $0.append(arguments) } }
        return (GitCommitter(workspace: workspace, path: remote.path(clone), access: access), workspace)
    }

    func settle(_ committer: GitCommitter) async {
        for _ in 0 ..< 1000 where committer.isBusy {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func write(_ text: String, _ file: String, in remote: GitTestRemote, _ clone: String = "a") throws {
        let path = remote.path(clone) + "/" + file
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The files of the last commit, and what is still uncommitted.
    struct Left: Equatable {
        var staged: [String] = []
        var unstaged: [String] = []
        var untracked: [String] = []
    }

    func lastCommit(_ remote: GitTestRemote, _ clone: String = "a") throws -> (files: [String], left: Left) {
        func names(_ arguments: [String]) throws -> [String] {
            try remote.output(arguments, in: remote.path(clone)).split(separator: "\n").map(String.init).sorted()
        }
        return try (names(["show", "--name-only", "--format=", "HEAD"]), Left(
            staged: names(["diff", "--cached", "--name-only"]),
            unstaged: names(["diff", "--name-only"]),
            untracked: names(["ls-files", "--others", "--exclude-standard"])
        ))
    }

    @Test func theStagedFilesAreCheckedAndACommitHoldsExactlyTheCheckedOnes() async throws {
        let remote = try GitTestRemote()
        try remote.commit("old.txt", "old", in: "a")
        try remote.commit("keep.txt", "keep", in: "a")
        try write("staged", "staged.txt", in: remote)
        try remote.run(["add", "staged.txt"], in: remote.path("a"))
        try write("changed", "README.md", in: remote)
        try write("new", "new/deep/file.txt", in: remote)
        try FileManager.default.removeItem(atPath: remote.path("a") + "/old.txt")
        try write("other", "keep.txt", in: remote)
        let (committer, _) = committer(remote, "a")
        await settle(committer)
        let files = try #require(committer.changes?.files)
        #expect(files.map(\.path).sorted() == ["README.md", "keep.txt", "new/deep/file.txt", "old.txt", "staged.txt"])
        #expect(committer.checked == ["staged.txt"]) // the staged ones at first
        #expect(committer.recentMessages.first == "keep.txt")

        // The staged one unchecked; a changed, a new and a deleted file checked.
        committer.perform(.check(["staged.txt"], false))
        committer.perform(.check(["README.md", "new/deep/file.txt", "old.txt", "not/listed.txt"], true))
        #expect(committer.checked == ["README.md", "new/deep/file.txt", "old.txt"])
        #expect(!committer.canCommit(message: " \n "))
        #expect(committer.canCommit(message: "Three files"))
        committer.perform(.commit(message: "Three files\n\nand a body", push: false))
        #expect(committer.running == .add) // the new file is added first
        await settle(committer)
        #expect(committer.outcome == .committed(pushed: false))
        let (committed, left) = try lastCommit(remote)
        #expect(committed == ["README.md", "new/deep/file.txt", "old.txt"])
        #expect(left == Left(staged: ["staged.txt"], unstaged: ["keep.txt"])) // still staged, and not committed
        #expect(try remote.output(["log", "-1", "--format=%B"], in: remote.path("a")) == "Three files\n\nand a body")
        // Read again: what was committed is gone, the rest keeps its check.
        #expect(committer.changes?.files.map(\.path).sorted() == ["keep.txt", "staged.txt"])
        #expect(committer.checked.isEmpty)
        #expect(committer.recentMessages.first == "Three files\n\nand a body")
        #expect(!committer.canCommit(message: "nothing checked"))
    }

    /// Names are names: "a*.txt" commits that file only, a name starting with "-" is no option,
    /// and a rename takes its old name along.
    @Test func namesAreTakenLiterally() async throws {
        let remote = try GitTestRemote()
        try remote.commit("before.txt", "same", in: "a")
        for name in ["a*.txt", "abc.txt", "-n.txt", ":(top)x.txt"] {
            try write(name, name, in: remote)
        }
        try remote.run(["mv", "before.txt", "after.txt"], in: remote.path("a"))
        let (committer, _) = committer(remote, "a")
        await settle(committer)
        #expect(committer.checked == ["after.txt"]) // staged
        #expect(committer.changes?.files.first { $0.path == "after.txt" }?.oldPath == "before.txt")
        committer.perform(.check(["a*.txt", "-n.txt", ":(top)x.txt"], true))
        committer.perform(.commit(message: "Odd names", push: false))
        await settle(committer)
        #expect(committer.outcome == .committed(pushed: false))
        let (committed, left) = try lastCommit(remote)
        #expect(committed == ["-n.txt", ":(top)x.txt", "a*.txt", "after.txt"])
        #expect(left == Left(untracked: ["abc.txt"]))
        #expect(try remote.output(["show", "--stat", "--format=", "-M", "HEAD"], in: remote.path("a"))
            .contains("before.txt => after.txt"))
    }

    @Test func commitAndPush() async throws {
        let remote = try GitTestRemote()
        try write("pushed", "README.md", in: remote)
        let (committer, _) = committer(remote, "a")
        await settle(committer)
        #expect(committer.changes?.upstream == "origin/main")
        committer.perform(.checkAll(true))
        committer.perform(.commit(message: "Pushed", push: true))
        #expect(committer.running == .commit)
        await settle(committer)
        #expect(committer.outcome == .committed(pushed: true))
        #expect(committer.output.contains("main -> main"))
        #expect(try remote.output(["log", "-1", "--format=%s", "main"], in: remote.root + "/remote.git") == "Pushed")
    }

    /// A commit that git refuses (a hook says no) is shown with git's output; nothing is pushed,
    /// and the files it was given are cleaned up.
    @Test func aRefusedCommitIsShownAndNotPushed() async throws {
        let remote = try GitTestRemote()
        let hooks = remote.root + "/hooks-a"
        try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        try "#!/bin/sh\necho 'no commits today' >&2\nexit 1\n".write(toFile: hooks + "/pre-commit", atomically: true,
                                                                     encoding: .utf8)
        chmod(hooks + "/pre-commit", 0o755)
        try write("refused", "README.md", in: remote)
        let before = try remote.output(["rev-parse", "main"], in: remote.root + "/remote.git")
        let copies = NSTemporaryDirectory() + "Blitter-Git"
        let earlier = Set((try? FileManager.default.contentsOfDirectory(atPath: copies)) ?? [])
        let (committer, _) = committer(remote, "a")
        await settle(committer)
        committer.perform(.checkAll(true))
        committer.perform(.commit(message: "Refused", push: true))
        await settle(committer)
        guard case let .failed(step, message) = committer.outcome else {
            Issue.record("expected a failure, got \(String(describing: committer.outcome))")
            return
        }
        #expect(step == .commit && message.contains("exit code 1"))
        #expect(committer.output.contains("no commits today"))
        #expect(try remote.output(["rev-parse", "main"], in: remote.root + "/remote.git") == before)
        #expect(committer.checked == ["README.md"]) // still there to try again
        let left = try FileManager.default.contentsOfDirectory(atPath: copies).filter {
            !earlier.contains($0) && FileManager.default.fileExists(atPath: copies + "/" + $0 + "/message")
        }
        #expect(left.isEmpty)
    }

    /// A refresh keeps the user's checks; a file staged since then is checked.
    @Test func aRefreshKeepsTheChecks() async throws {
        let remote = try GitTestRemote()
        try write("one", "one.txt", in: remote)
        try remote.run(["add", "one.txt"], in: remote.path("a"))
        let (committer, _) = committer(remote, "a")
        await settle(committer)
        committer.perform(.check(["one.txt"], false))
        try write("two", "two.txt", in: remote)
        try remote.run(["add", "two.txt"], in: remote.path("a"))
        committer.perform(.refresh)
        await settle(committer)
        #expect(committer.checked == ["two.txt"])
    }

    /// A double-click: the committed version beside the file on disk; a new file has an empty
    /// one before, a deleted one an empty one after, a renamed one its old name's before.
    @Test func aFileIsComparedWithItsCommittedVersion() async throws {
        let remote = try GitTestRemote()
        try remote.commit("gone.txt", "was here", in: "a")
        try remote.commit("old-name.txt", "renamed", in: "a")
        try write("hello again", "README.md", in: remote)
        try write("brand new", "fresh.txt", in: remote)
        try FileManager.default.removeItem(atPath: remote.path("a") + "/gone.txt")
        try remote.run(["mv", "old-name.txt", "new-name.txt"], in: remote.path("a"))
        let launches = CommitTestLaunches()
        let (committer, workspace) = committer(remote, "a", launches: launches)
        await settle(committer)
        var shown: [(before: String, after: String?)] = []
        for (index, path) in ["README.md", "fresh.txt", "gone.txt", "new-name.txt"].enumerated() {
            committer.perform(.compare(path))
            await settle(committer)
            for _ in 0 ..< 300 where workspace.compareWork != nil || launches.calls.withLock({ $0 }).count <= index {
                try await Task.sleep(for: .milliseconds(5))
            }
            let call = try #require(launches.calls.withLock { $0 }.last)
            #expect(call[1].contains("/Blitter-Git/") && call[1].hasSuffix("/HEAD/" + path))
            try shown.append((String(contentsOfFile: call[1], encoding: .utf8),
                              call[2].hasPrefix(remote.path("a")) ? nil : String(contentsOfFile: call[2],
                                                                                 encoding: .utf8)))
            if index != 2 {
                #expect(call[2] == remote.path("a") + "/" + path) // the real file, editable there
            }
        }
        #expect(shown.map(\.before) == ["hello", "", "was here", "renamed"])
        #expect(shown[2].after == "") // deleted
        #expect(committer.problem == nil)
    }

    @Test func theFirstCommitOfANewRepository() async throws {
        let remote = try GitTestRemote()
        let fresh = remote.root + "/fresh"
        try remote.run(["init", "-q", "-b", "main", fresh], in: remote.root)
        for (key, value) in [("user.name", "T"), ("user.email", "t@example.invalid"), ("commit.gpgsign", "false")] {
            try remote.run(["config", key, value], in: fresh)
        }
        try "first".write(toFile: fresh + "/first.txt", atomically: true, encoding: .utf8)
        let workspace = Workspace(initialLocation: "/", home: "/", lister: { _ in [] }, directoryCheck: { _ in false },
                                  volumes: { [] }, watcher: { _ in CommitTestWatcher() })
        workspace.gitRepositories[fresh] = KnownRepository(GitRepoStatus(), checked: Date())
        let committer = GitCommitter(workspace: workspace, path: fresh)
        await settle(committer)
        #expect(committer.changes?.hasCommits == false && committer.recentMessages.isEmpty)
        #expect(committer.changes?.upstream == nil)
        committer.perform(.checkAll(true))
        committer.perform(.commit(message: "The very first", push: false))
        await settle(committer)
        #expect(committer.outcome == .committed(pushed: false))
        #expect(committer.recentMessages == ["The very first"] && committer.changes?.files == [])
    }

    @Test func withoutGitOrAWorkingCopyItSaysWhy() async throws {
        let remote = try GitTestRemote()
        try write("x", "x.txt", in: remote)
        let access = GitCommitAccess(changes: GitCommitAccess.real.changes, messages: GitCommitAccess.real.messages,
                                     contents: GitCommitAccess.real.contents, git: nil)
        let (noGit, _) = committer(remote, "a", access: access)
        await settle(noGit)
        noGit.perform(.checkAll(true))
        noGit.perform(.commit(message: "x", push: false))
        #expect(noGit.problem?.hasPrefix("No git was found") == true && noGit.running == nil)

        let workspace = Workspace(initialLocation: "/", home: "/", lister: { _ in [] }, directoryCheck: { _ in false },
                                  volumes: { [] }, watcher: { _ in CommitTestWatcher() })
        let outside = GitCommitter(workspace: workspace, path: "/nowhere")
        #expect(outside.root == nil && outside.problem == "“/nowhere” is not in a git working copy.")
        #expect(!outside.canCommit(message: "x"))
    }
}
