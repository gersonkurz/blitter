@testable import BlitterCore
@testable import BlitterGit
@testable import BlitterModel
import Foundation
import Testing

/// Git Commit (#44): what its first review found, against a real git.
extension GitCommitterTests {
    /// #44 review: a rename's old name in use again is a file of its own; committing only the
    /// rename leaves that file's new contents out. A copy's source is never named.
    @Test func aRenamesOldNameInUseAgainIsNotCommittedWithIt() async throws {
        let remote = try GitTestRemote()
        try remote.commit("old.txt", "original", in: "a")
        try remote.run(["mv", "old.txt", "new.txt"], in: remote.path("a"))
        try write("unrelated new contents", "old.txt", in: remote)
        let (committer, _) = committer(remote, "a")
        await settle(committer)
        let files = try #require(committer.changes?.files)
        #expect(files.map(\.path) == ["new.txt", "old.txt"])
        #expect(committer.checked == ["new.txt"])
        committer.perform(.commit(message: "Only the rename", push: false))
        await settle(committer)
        #expect(committer.outcome == .committed(pushed: false))
        #expect(try lastCommit(remote).files == ["new.txt"])
        #expect(try remote.output(["show", "HEAD:old.txt"], in: remote.path("a")) == "original")
        #expect(remote.text("old.txt", in: "a") == "unrelated new contents") // untouched on disk

        let copy = GitFileChange(path: "copy.txt", oldPath: "source.txt", staged: "C")
        let rename = GitFileChange(path: "b.txt", oldPath: "a.txt", staged: "R")
        #expect(GitCommitPlan.paths(of: [copy, rename]) { _ in false } == ["copy.txt", "b.txt", "a.txt"])
        #expect(GitCommitPlan.paths(of: [copy, rename]) { _ in true } == ["copy.txt", "b.txt"])
    }

    /// #44 review, round 2: the old name taken by an ignored file (so not listed at all), then by
    /// a folder with a staged file of its own: neither goes into the rename. One commit each, so
    /// each case is shown on its own (git refuses a folder named as a file outright).
    @Test func aRenamesOldNameTakenByAnIgnoredFileOrAFolder() async throws {
        let remote = try GitTestRemote()
        try remote.commit("old.txt", "original", in: "a")
        try remote.commit("other.txt", "original", in: "a")
        try remote.run(["mv", "other.txt", "moved.txt"], in: remote.path("a"))
        try write("secret", "other.txt", in: remote)
        try "other.txt\n".write(toFile: remote.path("a") + "/.git/info/exclude", atomically: true, encoding: .utf8)
        let (committer, _) = committer(remote, "a")
        await settle(committer)
        #expect(committer.changes?.files.map(\.path) == ["moved.txt"])
        committer.perform(.commit(message: "Ignored", push: false))
        await settle(committer)
        #expect(committer.outcome == .committed(pushed: false))
        #expect(try lastCommit(remote).files == ["moved.txt"])
        #expect(try remote.output(["show", "HEAD:other.txt"], in: remote.path("a")) == "original") // not "secret"

        try remote.run(["mv", "old.txt", "new.txt"], in: remote.path("a"))
        try write("staged, unchecked", "old.txt/child.txt", in: remote) // a folder now
        try remote.run(["add", "old.txt/child.txt"], in: remote.path("a"))
        committer.perform(.refresh)
        await settle(committer)
        #expect(committer.changes?.files.map(\.path).sorted() == ["new.txt", "old.txt/child.txt", "other.txt"])
        committer.perform(.check(["old.txt/child.txt", "other.txt"], false))
        #expect(committer.checked == ["new.txt"])
        committer.perform(.commit(message: "Folder", push: false))
        await settle(committer)
        #expect(committer.outcome == .committed(pushed: false))
        #expect(try lastCommit(remote).files == ["new.txt"])
        #expect(try lastCommit(remote).left.staged.contains("old.txt/child.txt")) // still staged, not committed
    }

    /// #44 review: the window (and its committer) may go away while a commit runs; the steps
    /// still run to the end, push included, and their files are removed.
    @Test func theStepsGoOnWhenTheCommitterIsGone() async throws {
        let remote = try GitTestRemote()
        let hooks = remote.root + "/hooks-a"
        try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        try "#!/bin/sh\nsleep 1\n".write(toFile: hooks + "/pre-commit", atomically: true, encoding: .utf8)
        chmod(hooks + "/pre-commit", 0o755)
        try write("late", "late.txt", in: remote)
        let copies = NSTemporaryDirectory() + "Blitter-Git"
        let earlier = Set((try? FileManager.default.contentsOfDirectory(atPath: copies)) ?? [])
        var made: (GitCommitter, Workspace)? = committer(remote, "a")
        let workspace = try #require(made).1
        weak var gone = made?.0
        try await settle(#require(gone))
        gone?.perform(.checkAll(true))
        gone?.perform(.commit(message: "Late", push: true))
        for _ in 0 ..< 300 where workspace.jobs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!workspace.jobs.isEmpty) // the add step runs
        made = nil
        #expect(gone == nil) // the window and its committer are gone
        let remoteGit = remote.root + "/remote.git"
        // Runs git each time: stops as soon as it is there (a `for … where` would go on asking).
        var waited = 0
        while (try? remote.output(["log", "-1", "--format=%s", "main"], in: remoteGit)) != "Late", waited < 1000 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(try remote.output(["log", "-1", "--format=%s", "main"], in: remoteGit) == "Late")
        func left() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: copies)) ?? []).filter {
                !earlier.contains($0) && FileManager.default.fileExists(atPath: copies + "/" + $0 + "/message")
            }
        }
        for _ in 0 ..< 300 where !left().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(left().isEmpty)
    }

    /// #44 review: a commit that cannot be prepared leaves nothing behind.
    @Test func aFailedPreparationLeavesNothingBehind() {
        let folder = NSTemporaryDirectory() + "BlitterPlan-" + UUID().uuidString
        var writes = 0
        let result = GitCommitPlan.prepare(
            message: "x", chosen: [GitFileChange(path: "a.txt", unstaged: "M")], root: "/nowhere", git: "/git",
            push: false, folder: folder
        ) { data, path in
            writes += 1
            guard writes < 2 else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: URL(fileURLWithPath: path))
        }
        guard case let .failure(failure) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(writes == 2 && failure.message.hasPrefix("The commit could not be prepared"))
        #expect(!FileManager.default.fileExists(atPath: folder))
    }

    /// #44 review: Cancel while the commit is being prepared: nothing runs.
    @Test func cancelWhilePreparing() async throws {
        let remote = try GitTestRemote()
        try write("x", "README.md", in: remote)
        let (committer, workspace) = committer(remote, "a")
        await settle(committer)
        let head = try remote.output(["rev-parse", "HEAD"], in: remote.path("a"))
        committer.perform(.checkAll(true))
        committer.perform(.commit(message: "Never", push: false))
        committer.perform(.cancel) // before the preparation is back
        await settle(committer)
        #expect(committer.outcome == .cancelled(.commit))
        #expect(workspace.jobs.isEmpty)
        #expect(try remote.output(["rev-parse", "HEAD"], in: remote.path("a")) == head)
    }

    /// #44 review: `git rm --cached`: the file's deletion is staged, yet it is on disk; one row,
    /// compared with the file itself, not with an empty one.
    @Test func aStagedDeletionStillOnDiskIsComparedWithTheFile() async throws {
        let remote = try GitTestRemote()
        try remote.run(["rm", "-q", "--cached", "README.md"], in: remote.path("a"))
        let launches = CommitTestLaunches()
        let (committer, workspace) = committer(remote, "a", launches: launches)
        await settle(committer)
        #expect(committer.changes?.files == [GitFileChange(path: "README.md", staged: "D", unstaged: "?")])
        committer.perform(.compare("README.md"))
        await settle(committer)
        for _ in 0 ..< 300 where workspace.compareWork != nil || launches.calls.withLock({ $0 }).isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        let call = try #require(launches.calls.withLock { $0 }.first)
        #expect(try String(contentsOfFile: call[1], encoding: .utf8) == "hello") // it is in HEAD
        #expect(call[2] == remote.path("a") + "/README.md")
    }
}
