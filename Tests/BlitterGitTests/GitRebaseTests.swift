@testable import BlitterCore
@testable import BlitterGit
@testable import BlitterModel
import Foundation
import Synchronization
import Testing

private final class Unwatched: FolderWatching {
    func watch(_: Set<String>) {}
}

/// Fetch & Rebase in Git Sync (#45), against a real git: a clean rebase, and one that stops on a
/// conflict and is aborted.
@MainActor
@Suite(.serialized)
struct GitRebaseTests {
    private func sync(_ remote: GitTestRemote, _ clone: String) -> GitSync {
        let workspace = Workspace(initialLocation: "/", home: "/", lister: { _ in [] }, directoryCheck: { _ in false },
                                  volumes: { [] }, watcher: { _ in Unwatched() })
        workspace.gitRepositories[remote.path(clone)] = KnownRepository(GitRepoStatus(), checked: Date())
        return GitSync(workspace: workspace, path: remote.path(clone))
    }

    private func settle(_ sync: GitSync) async {
        for _ in 0 ..< 1000 where sync.isBusy {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func fetchAndRebasePutsTheLocalCommitOnTopOfTheUpstreams() async throws {
        let remote = try GitTestRemote()
        try remote.commit("from-a.txt", "a", in: "a")
        try remote.run(["push", "-q"], in: remote.path("a"))
        try remote.commit("from-b.txt", "b", in: "b")
        let bob = sync(remote, "b")
        await settle(bob)
        #expect(bob.canRun(.fetchAndRebase) && !bob.canRun(.abortRebase))
        bob.perform(.run(.fetchAndRebase))
        #expect(bob.running == .fetchAndRebase)
        await settle(bob)
        #expect(bob.outcome == .succeeded(.fetchAndRebase))
        #expect(bob.status?.ahead == 1 && bob.status?.behind == 0 && !bob.isRebasing)
        let subjects = try #require(Git.log(of: remote.path("b"))).map(\.subject)
        #expect(subjects == ["from-b.txt", "from-a.txt", "README.md"]) // fetched, then rebased
    }

    @Test func aConflictStopsTheRebaseWhichCanBeAborted() async throws {
        let remote = try GitTestRemote()
        try remote.commit("README.md", "from a", in: "a")
        try remote.run(["push", "-q"], in: remote.path("a"))
        try remote.commit("README.md", "from b", in: "b")
        let before = try remote.output(["rev-parse", "HEAD"], in: remote.path("b"))
        let bob = sync(remote, "b")
        await settle(bob)
        #expect(!Git.isRebasing(remote.path("b")))
        bob.perform(.run(.fetchAndRebase))
        await settle(bob)
        guard case let .failed(operation, message) = bob.outcome else {
            Issue.record("expected a failure, got \(String(describing: bob.outcome))")
            return
        }
        #expect(operation == .fetchAndRebase && message.contains("exit code"))
        #expect(bob.output.contains("README.md")) // git names the conflict (in the user's language)
        #expect(bob.isRebasing && Git.isRebasing(remote.path("b")))
        // Nothing else runs during the rebase.
        #expect(!bob.canRun(.push) && !bob.canRun(.fetch) && !bob.canRun(.pull) && bob.canRun(.abortRebase))
        bob.perform(.run(.push))
        #expect(bob.running == nil)

        bob.perform(.run(.abortRebase))
        await settle(bob)
        #expect(bob.outcome == .succeeded(.abortRebase))
        #expect(!bob.isRebasing && !Git.isRebasing(remote.path("b")))
        #expect(try remote.output(["rev-parse", "HEAD"], in: remote.path("b")) == before) // as it was
        #expect(remote.text("README.md", in: "b") == "from b")
        #expect(bob.status?.ahead == 1 && bob.status?.behind == 1)
    }

    /// The terminal tool opens the working copy (to finish a rebase there).
    @Test func openTerminalUsesTheTerminalTool() async throws {
        let remote = try GitTestRemote()
        let workspace = Workspace(initialLocation: "/", home: "/", lister: { _ in [] }, directoryCheck: { _ in false },
                                  volumes: { [] }, watcher: { _ in Unwatched() })
        workspace.gitRepositories[remote.path("a")] = KnownRepository(GitRepoStatus(), checked: Date())
        var opened: [(String, [String])] = []
        workspace.system.openWithApp = { app, paths, _ in opened.append((app, paths)) }
        let alice = GitSync(workspace: workspace, path: remote.path("a"))
        alice.perform(.openTerminal)
        #expect(opened.count == 1 && opened.first?.0 == "iTerm" && opened.first?.1 == [remote.path("a")])
        await settle(alice)
    }

    /// #45 review: when an operation ends, nothing can start until the state is read again (it
    /// may have left a rebase stopped); here that read is held back.
    @Test func nothingStartsBeforeTheStateIsReadAgain() async throws {
        let remote = try GitTestRemote()
        let script = remote.root + "/failing-git"
        try "#!/bin/sh\necho stopped\nexit 1\n".write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        let hold = Mutex(false)
        let rebasing = Mutex(false)
        let access = GitSyncAccess(status: { _, cancelled in
            while hold.withLock({ $0 }), !cancelled.isSet {
                Thread.sleep(forTimeInterval: 0.01)
            }
            var status = GitRepoStatus()
            status.branch = "main"
            status.upstream = "origin/main"
            return status
        }, lastFetch: { _, _ in nil }, rebasing: { _, _ in rebasing.withLock { $0 } }, git: script)
        let workspace = Workspace(initialLocation: "/", home: "/", lister: { _ in [] }, directoryCheck: { _ in false },
                                  volumes: { [] }, watcher: { _ in Unwatched() })
        workspace.gitRepositories[remote.path("a")] = KnownRepository(GitRepoStatus(), checked: Date())
        let sync = GitSync(workspace: workspace, path: remote.path("a"), access: access)
        await settle(sync)
        #expect(sync.canRun(.fetchAndRebase))
        hold.withLock { $0 = true } // the next read waits
        rebasing.withLock { $0 = true } // and will find the rebase stopped
        sync.perform(.run(.fetchAndRebase))
        for _ in 0 ..< 300 where sync.running != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sync.running == nil && sync.outcome.map {
            if case .failed = $0 {
                true
            } else {
                false
            }
        } == true)
        let none = GitSync.Operation.allCases.allSatisfy { !sync.canRun($0) }
        #expect(none) // still reading
        sync.perform(.run(.push))
        #expect(sync.running == nil && sync.output == "stopped\n") // nothing started, the output kept
        hold.withLock { $0 = false }
        await settle(sync)
        #expect(sync.isRebasing && !sync.canRun(.push) && sync.canRun(.abortRebase))
    }
}
