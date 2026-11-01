@testable import BlitterCore
@testable import BlitterModel
import Foundation
import Synchronization
import Testing

/// A pretend git: which folders are working copies, their status, and how often it was asked.
private final class FakeGit: Sendable {
    let roots: Mutex<Set<String>>
    let statuses: Mutex<[String: GitRepoStatus]>
    let reads = Mutex<[String]>([])
    /// While set, a read waits until it is cancelled (or 5 s pass); counts the cancelled ones.
    let blocking = Atomic(false)
    let cancelledReads = Atomic(0)

    init(_ statuses: [String: GitRepoStatus]) {
        roots = Mutex(Set(statuses.keys))
        self.statuses = Mutex(statuses)
    }

    var access: GitAccess {
        GitAccess(repositoryRoot: { [self] path in
            roots.withLock { $0 }.filter { path == $0 || path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
        }, isRepositoryRoot: { [self] path in roots.withLock { $0.contains(path) } },
        status: { [self] root, cancelled in
            reads.withLock { $0.append(root) }
            if blocking.load(ordering: .relaxed) {
                for _ in 0 ..< 500 where !cancelled.isSet {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if cancelled.isSet {
                    cancelledReads.add(1, ordering: .relaxed)
                    return nil
                }
            }
            return statuses.withLock { $0[root] }
        })
    }
}

/// Git states (#22): roots show their repository's state; folders inside show changes.
@MainActor
@Suite(.serialized)
struct GitTests {
    @Test func statesFollowTheOwnersRules() async throws {
        let sides = try SidesOnDisk()
        for folder in ["clean", "dirty", "ahead", "plain"] {
            try FileManager.default.createDirectory(
                atPath: sides.left + "/" + folder,
                withIntermediateDirectories: false
            )
        }
        let left = sides.left
        let git = FakeGit([
            left + "/clean": GitRepoStatus(),
            left + "/dirty": GitRepoStatus(changed: ["src/app/main.swift", "notes/", "top.txt"]),
            left + "/ahead": GitRepoStatus(ahead: 2),
        ])
        sides.workspace.gitAccess = git.access
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()

        let state = { sides.workspace.gitState(ofFolder: left + $0) }
        #expect(state("/clean") == .clean)
        #expect(state("/dirty") == .modified)
        #expect(state("/ahead") == .aheadOrBehind)
        #expect(state("/plain") == nil) // not a working copy
        // Inside a working copy: folders that contain changes; clean ones stay uncolored.
        #expect(state("/dirty/src") == .modified && state("/dirty/src/app") == .modified)
        #expect(state("/dirty/notes") == .modified) // an untracked folder
        #expect(state("/dirty/docs") == nil)
        #expect(state("/clean/src") == nil)
        #expect(GitState.modified.role == .gitModified)

        sides.workspace.settings.gitColors = false
        #expect(state("/dirty") == nil)
    }

    @Test func theWorkingCopyBeingViewedIsReadAgainItsNeighboursNotSoOften() async throws {
        let sides = try SidesOnDisk()
        try FileManager.default.createDirectory(atPath: sides.left + "/neighbour", withIntermediateDirectories: false)
        let left = sides.left
        // The side's own folder is a working copy, with another one inside.
        let git = FakeGit([left: GitRepoStatus(), left + "/neighbour": GitRepoStatus()])
        sides.workspace.gitAccess = git.access
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        #expect(git.reads.withLock { $0 }.sorted() == [left, left + "/neighbour"])

        git.reads.withLock { $0.removeAll() }
        sides.workspace.perform(.refresh(.left)) // e.g. a change on disk
        try await sides.settle()
        #expect(git.reads.withLock { $0 } == [left]) // the neighbour's status is still fresh
    }

    @Test func aChangedStatusRedrawsAnUnchangedOneDoesNot() async throws {
        let sides = try SidesOnDisk()
        let left = sides.left
        let git = FakeGit([left: GitRepoStatus()])
        sides.workspace.gitAccess = git.access
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        let version = sides.workspace.gitVersion
        #expect(sides.workspace.gitState(ofFolder: left) == .clean)

        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        #expect(sides.workspace.gitVersion == version) // read again, nothing new

        git.statuses.withLock { $0[left] = GitRepoStatus(changed: ["x.txt"]) }
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        #expect(sides.workspace.gitVersion == version + 1)
        #expect(sides.workspace.gitState(ofFolder: left) == .modified)
    }

    /// A newer listing, or turning git colors off, cancels a read that is still running.
    @Test func aReadThatIsStillRunningIsCancelled() async throws {
        let sides = try SidesOnDisk()
        let git = FakeGit([sides.left: GitRepoStatus()])
        sides.workspace.gitAccess = git.access
        git.blocking.store(true, ordering: .relaxed)
        sides.workspace.perform(.refresh(.left))
        try await waitFor { git.reads.withLock { $0.count } == 1 }
        sides.workspace.perform(.refresh(.left)) // replaces the blocked read
        try await waitFor { git.cancelledReads.load(ordering: .relaxed) == 1 }
        try await waitFor { git.reads.withLock { $0.count } == 2 }
        sides.workspace.settings.gitColors = false // and this one goes too
        try await waitFor { git.cancelledReads.load(ordering: .relaxed) == 2 }
        #expect(sides.workspace.gitState(ofFolder: sides.left) == nil)
    }

    /// Changes deep inside a working copy reach no watched folder; the regular re-read finds them.
    @Test func statusesAreReadAgainWithoutAListing() async throws {
        let sides = try SidesOnDisk()
        let git = FakeGit([sides.left: GitRepoStatus()])
        sides.workspace.gitAccess = git.access
        sides.workspace.gitRefreshInterval = 0.1
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        #expect(sides.workspace.gitState(ofFolder: sides.left) == .clean)
        git.statuses.withLock { $0[sides.left] = GitRepoStatus(changed: ["deep/inside/file.txt"]) }
        try await waitFor { sides.workspace.gitState(ofFolder: sides.left) == .modified }
        sides.workspace.settings.gitColors = false // stops the re-reading
    }

    /// A folder that stops being a working copy loses its color, and so do the folders in it.
    @Test func aRemovedWorkingCopyIsForgotten() async throws {
        let sides = try SidesOnDisk()
        try FileManager.default.createDirectory(atPath: sides.left + "/repo", withIntermediateDirectories: false)
        let repo = sides.left + "/repo"
        let git = FakeGit([repo: GitRepoStatus(changed: ["src/a.txt"])])
        sides.workspace.gitAccess = git.access
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        #expect(sides.workspace.gitState(ofFolder: repo) == .modified)
        #expect(sides.workspace.gitState(ofFolder: repo + "/src") == .modified)

        git.roots.withLock { $0.removeAll() } // its .git is gone
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        #expect(sides.workspace.gitState(ofFolder: repo) == nil)
        #expect(sides.workspace.gitState(ofFolder: repo + "/src") == nil)

        // The same for the working copy the side is in.
        git.roots.withLock { $0 = [sides.left] }
        git.statuses.withLock { $0[sides.left] = GitRepoStatus() }
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        #expect(sides.workspace.gitState(ofFolder: sides.left) == .clean)
        git.roots.withLock { $0.removeAll() }
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        #expect(sides.workspace.gitState(ofFolder: sides.left) == nil)
    }

    /// Going into a submodule keeps the working copy around it: it is still one.
    @Test func aNestedWorkingCopyKeepsTheOneAroundIt() async throws {
        let sides = try SidesOnDisk()
        try FileManager.default.createDirectory(atPath: sides.left + "/sub", withIntermediateDirectories: false)
        let outer = sides.left
        let inner = sides.left + "/sub"
        let git = FakeGit([outer: GitRepoStatus(changed: ["notes/a.txt"]), inner: GitRepoStatus()])
        sides.workspace.gitAccess = git.access
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        sides.workspace.perform(.navigate(.left, path: inner))
        try await sides.settle()
        #expect(sides.workspace.gitState(ofFolder: inner) == .clean)
        #expect(sides.workspace.gitState(ofFolder: outer) == .modified)
        #expect(sides.workspace.gitState(ofFolder: outer + "/notes") == .modified)
    }

    /// Slow working copies, more of them than one refresh interval can read: the regular re-read
    /// does not start the scan over, so their states still arrive.
    @Test func aSlowScanIsNotStartedOverByTheRegularReRead() async throws {
        let sides = try SidesOnDisk()
        var statuses: [String: GitRepoStatus] = [:]
        for index in 0 ..< 4 {
            try FileManager.default.createDirectory(
                atPath: sides.left + "/repo\(index)",
                withIntermediateDirectories: false
            )
            statuses[sides.left + "/repo\(index)"] = GitRepoStatus(ahead: 1)
        }
        let slow = FakeGit(statuses)
        let access = slow.access
        sides.workspace.gitAccess = GitAccess(repositoryRoot: access.repositoryRoot,
                                              isRepositoryRoot: access.isRepositoryRoot)
        { root, cancelled in
            Thread.sleep(forTimeInterval: 0.1) // 4 × 0.1 s, against a 0.15 s interval
            return access.status(root, cancelled)
        }
        sides.workspace.gitRefreshInterval = 0.15
        sides.workspace.perform(.refresh(.left))
        try await waitFor {
            (0 ..< 4).allSatisfy { sides.workspace.gitState(ofFolder: sides.left + "/repo\($0)") != nil }
        }
        sides.workspace.settings.gitColors = false // stops the re-reading
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test func noGitColorsNoGitRuns() async throws {
        let sides = try SidesOnDisk()
        let git = FakeGit([sides.left: GitRepoStatus()])
        sides.workspace.gitAccess = git.access
        sides.workspace.settings.gitColors = false
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        #expect(git.reads.withLock { $0 }.isEmpty)
    }
}
