@testable import BlitterCore
@testable import BlitterGit
@testable import BlitterModel
import Foundation
import Synchronization
import Testing

private final class Silent: FolderWatching {
    func watch(_: Set<String>) {}
}

/// Git Sync (#43), against a real git: a bare "remote" and two clones in a temporary folder;
/// Fetch, Pull and Push run as real jobs.
@MainActor
@Suite(.serialized)
struct GitSyncTests {
    private func sync(_ remote: GitTestRemote, _ clone: String, access: GitSyncAccess = .real) -> GitSync {
        let workspace = Workspace(initialLocation: "/", home: "/", lister: { _ in [] }, directoryCheck: { _ in false },
                                  volumes: { [] }, watcher: { _ in Silent() })
        workspace.gitRepositories[remote.path(clone)] = KnownRepository(GitRepoStatus(), checked: Date())
        return GitSync(workspace: workspace, path: remote.path(clone) + "/README.md", access: access)
    }

    private func settle(_ sync: GitSync) async {
        for _ in 0 ..< 1000 where sync.isBusy {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func pushThenFetchAndPullOnTheOtherClone() async throws {
        let remote = try GitTestRemote()
        let alice = sync(remote, "a")
        await settle(alice)
        #expect(alice.root == remote.path("a"))
        #expect(alice.status?.branch == "main" && alice.status?.upstream == "origin/main")
        #expect(alice.status?.ahead == 0 && alice.status?.behind == 0)

        try remote.commit("new.txt", "news", in: "a")
        alice.perform(.refresh)
        await settle(alice)
        #expect(alice.status?.ahead == 1)
        alice.perform(.run(.push))
        #expect(alice.running == .push) // a job in the strip
        await settle(alice)
        #expect(alice.outcome == .succeeded(.push))
        #expect(alice.output.contains("main -> main"))
        #expect(alice.status?.ahead == 0)

        let bob = sync(remote, "b")
        await settle(bob)
        bob.perform(.run(.fetch))
        await settle(bob)
        #expect(bob.outcome == .succeeded(.fetch))
        #expect(bob.status?.behind == 1)
        #expect(bob.lastFetch.map { abs($0.timeIntervalSinceNow) < 60 } == true)
        bob.perform(.run(.pull))
        await settle(bob)
        #expect(bob.outcome == .succeeded(.pull))
        #expect(bob.status?.behind == 0)
        #expect(FileManager.default.fileExists(atPath: remote.path("b") + "/new.txt"))
    }

    @Test func aRejectedPushIsShownNotForced() async throws {
        let remote = try GitTestRemote()
        try remote.commit("from-a.txt", "a", in: "a")
        try remote.run(["push", "-q"], in: remote.path("a"))
        try remote.commit("from-b.txt", "b", in: "b") // b has not pulled: its push is rejected
        let before = try remote.output(["rev-parse", "main"], in: remote.root + "/remote.git")
        let bob = sync(remote, "b")
        await settle(bob)
        bob.perform(.run(.push))
        await settle(bob)
        guard case let .failed(operation, message) = bob.outcome else {
            Issue.record("expected a failure, got \(String(describing: bob.outcome))")
            return
        }
        #expect(operation == .push && message.contains("exit code 1"))
        #expect(bob.output.contains("rejected"))
        // Nothing forced: the remote's branch is where it was.
        #expect(try remote.output(["rev-parse", "main"], in: remote.root + "/remote.git") == before)
    }

    /// #43 review: Pull rewrites local history (rebase): with commits on both sides, the local
    /// one ends up on top of the remote's, both files are there, and nothing is left to pull.
    @Test func aPullRebasesLocalCommitsOntoTheRemotes() async throws {
        let remote = try GitTestRemote()
        try remote.commit("from-a.txt", "a", in: "a")
        try remote.run(["push", "-q"], in: remote.path("a"))
        try remote.commit("from-b.txt", "b", in: "b")
        try "work in progress".write(toFile: remote.path("b") + "/README.md", atomically: true, encoding: .utf8)
        try remote.run(["stash", "-q"], in: remote.path("b")) // a clean tree; the stash is local state too
        let bob = sync(remote, "b")
        await settle(bob)
        bob.perform(.run(.fetch))
        await settle(bob)
        #expect(bob.status?.ahead == 1 && bob.status?.behind == 1)
        bob.perform(.run(.pull))
        await settle(bob)
        #expect(bob.outcome == .succeeded(.pull))
        #expect(bob.status?.ahead == 1 && bob.status?.behind == 0)
        let subjects = try #require(Git.log(of: remote.path("b"))).map(\.subject)
        #expect(subjects == ["from-b.txt", "from-a.txt", "README.md"]) // b's commit on top of a's
        #expect(FileManager.default.fileExists(atPath: remote.path("b") + "/from-a.txt"))
        #expect(FileManager.default.fileExists(atPath: remote.path("b") + "/from-b.txt"))
        #expect(try remote.output(["stash", "list"], in: remote.path("b")).contains("WIP")) // still there
    }

    /// #43 review: a worktree's `.git` is a file; its last fetch is still found.
    @Test func theLastFetchOfAWorktreeIsFound() async throws {
        let remote = try GitTestRemote()
        let worktree = remote.root + "/tree"
        try remote.run(["worktree", "add", "-q", "-b", "side", worktree], in: remote.path("a"))
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: worktree + "/.git", isDirectory: &isFolder) && !isFolder
            .boolValue)
        #expect(Git.lastFetch(of: worktree) == nil) // never fetched
        let workspace = Workspace(initialLocation: "/", home: "/", lister: { _ in [] }, directoryCheck: { _ in false },
                                  volumes: { [] }, watcher: { _ in Silent() })
        workspace.gitRepositories[worktree] = KnownRepository(GitRepoStatus(), checked: Date())
        let tree = GitSync(workspace: workspace, path: worktree)
        await settle(tree)
        #expect(tree.lastFetch == nil)
        tree.perform(.run(.fetch))
        await settle(tree)
        #expect(tree.outcome == .succeeded(.fetch))
        #expect(tree.lastFetch.map { abs($0.timeIntervalSinceNow) < 60 } == true)
    }

    /// #43 review: a status read that is replaced stops its last-fetch lookup too.
    @Test func aReplacedRefreshStopsItsLastFetchLookup() async throws {
        let remote = try GitTestRemote()
        let started = Mutex(0)
        let sawCancel = Mutex(false)
        let access = GitSyncAccess(status: { _, _ in GitRepoStatus() }, lastFetch: { _, cancelled in
            let first = started.withLock { count in
                count += 1
                return count == 1
            }
            guard first else {
                return nil
            }
            for _ in 0 ..< 300 where !cancelled.isSet { // the first one is slow
                Thread.sleep(forTimeInterval: 0.01)
            }
            sawCancel.withLock { $0 = cancelled.isSet }
            return nil
        }, git: remote.git)
        let alice = sync(remote, "a", access: access)
        try await Task.sleep(for: .milliseconds(50)) // the first lookup is waiting
        let start = Date()
        alice.perform(.refresh) // replaces it
        await settle(alice)
        for _ in 0 ..< 100 where !sawCancel.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sawCancel.withLock { $0 })
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func aRunningOperationCanBeCancelled() async throws {
        let remote = try GitTestRemote()
        let script = remote.root + "/slow-git"
        try "#!/bin/sh\necho starting\nsleep 30\n".write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        let access = GitSyncAccess(
            status: { Git.status(of: $0, cancelled: $1) },
            lastFetch: { _, _ in nil },
            git: script
        )
        let alice = sync(remote, "a", access: access)
        await settle(alice)
        alice.perform(.run(.fetch))
        for _ in 0 ..< 200 where !alice.output.contains("starting") {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(alice.output == "starting\n") // the output arrives while it runs
        let start = Date()
        alice.perform(.cancel)
        await settle(alice)
        #expect(alice.outcome == .cancelled(.fetch))
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func withoutGitOrAWorkingCopyItSaysWhy() async throws {
        let remote = try GitTestRemote()
        let noGit = sync(
            remote,
            "a",
            access: GitSyncAccess(status: { _, _ in nil }, lastFetch: { _, _ in nil }, git: nil)
        )
        await settle(noGit)
        noGit.perform(.run(.fetch))
        #expect(noGit.problem?.hasPrefix("No git was found") == true && noGit.running == nil)

        let workspace = Workspace(initialLocation: "/", home: "/", lister: { _ in [] }, directoryCheck: { _ in false },
                                  volumes: { [] }, watcher: { _ in Silent() })
        let outside = GitSync(workspace: workspace, path: "/nowhere")
        #expect(outside.root == nil && outside.problem == "“/nowhere” is not in a git working copy.")
        outside.perform(.run(.push))
        #expect(outside.running == nil)
    }
}
