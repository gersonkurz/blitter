@testable import BlitterCore
@testable import BlitterGit
@testable import BlitterModel
import Foundation
import Testing

/// Git Clone (#70), against a real git: the bare "remote" of `GitTestRemote` cloned into a folder
/// a side shows.
@MainActor
@Suite(.serialized)
struct GitCloneTests {
    private func workspace(showing folder: String) async -> Workspace {
        let workspace = Workspace(initialLocation: folder, home: folder, directoryCheck: { _ in false },
                                  volumes: { [] }, watcher: { _ in SilentWatcher() })
        await waitUntil { workspace.state(of: .left).status == .loaded }
        return workspace
    }

    private func settle(_ clone: GitClone, _: Workspace) async {
        await waitUntil { clone.state != .cloning }
    }

    /// Once it has looked for git (off the main thread).
    private func ready(_ clone: GitClone) async throws -> GitClone {
        await waitUntil { clone.isReady }
        try #require(clone.isReady)
        return clone
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 1000 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func theNameComesFromTheAddress() {
        #expect(GitClone.name(from: "https://github.com/me/project.git") == "project")
        #expect(GitClone.name(from: "git@github.com:me/project.git") == "project")
        #expect(GitClone.name(from: " https://host/me/project/ \n") == "project")
        #expect(GitClone.name(from: "/Users/me/remote.git") == "remote")
        #expect(GitClone.name(from: "host:project") == "project")
        #expect(GitClone.name(from: "").isEmpty)
    }

    @Test func clonesIntoTheFolderAndSelectsTheClone() async throws {
        let remote = try GitTestRemote()
        let workspace = await workspace(showing: remote.root)
        let clone = try await ready(GitClone(
            workspace: workspace,
            folder: remote.root,
            findGit: { [git = remote.git] in git }
        ))
        #expect(clone.problem(address: remote.root + "/remote.git", name: "c") == nil)
        #expect(clone.clone(address: remote.root + "/remote.git", name: "c"))
        #expect(clone.state == .cloning && workspace.jobs.count == 1) // a job in the strip
        await settle(clone, workspace)
        #expect(clone.state == .succeeded)
        #expect(FileManager.default.fileExists(atPath: remote.root + "/c/README.md"))
        await waitUntil { workspace.state(of: .left).selection == ["c"] } // once it is listed
        #expect(workspace.state(of: .left).selection == ["c"])
        #expect(clone.output.contains("'c'"), "output: [\(clone.output)]") // in the Mac's language
    }

    @Test func aFailedCloneSaysWhy() async throws {
        let remote = try GitTestRemote()
        let workspace = await workspace(showing: remote.root)
        let clone = try await ready(GitClone(
            workspace: workspace,
            folder: remote.root,
            findGit: { [git = remote.git] in git }
        ))
        #expect(clone.clone(address: remote.root + "/no-such.git", name: "d"))
        await settle(clone, workspace)
        guard case let .failed(message) = clone.state else {
            Issue.record("expected a failure: \(clone.state)")
            return
        }
        #expect(!message.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: remote.root + "/d"))
    }

    @Test func whatCannotBeClonedIsSaidBeforeStarting() async throws {
        let remote = try GitTestRemote()
        let workspace = await workspace(showing: remote.root)
        let clone = try await ready(GitClone(
            workspace: workspace,
            folder: remote.root,
            findGit: { [git = remote.git] in git }
        ))
        #expect(clone.problem(address: " ", name: "x") != nil)
        #expect(clone.problem(address: "a\nb", name: "x") != nil)
        #expect(clone.problem(address: "u", name: "") != nil)
        #expect(clone.problem(address: "u", name: "a/b") != nil && clone.problem(address: "u", name: "..") != nil)
        #expect(clone.problem(address: "u", name: "A")?.contains("already") == true) // the clone "a", any case
        #expect(try await ready(GitClone(workspace: workspace, folder: remote.root, findGit: { nil })).problem(
            address: "u",
            name: "x"
        ) != nil)
        #expect(!clone.clone(address: "u", name: "a") && workspace.jobs.isEmpty) // refused: nothing starts
    }
}

final class SilentWatcher: FolderWatching {
    func watch(_: Set<String>) {}
}

extension GitCloneTests {
    /// Looking for git looks at the disk: never on the main thread (#70 review).
    @Test func gitIsLookedForOffTheMainThread() async throws {
        let onMain = OnMainFlag()
        let workspace = Workspace(initialLocation: "/", home: "/", lister: { _ in [] }, volumes: { [] },
                                  watcher: { _ in SilentWatcher() })
        let clone = GitClone(workspace: workspace, folder: "/") {
            onMain.set(Thread.isMainThread)
            return "/usr/bin/true"
        }
        for _ in 0 ..< 300 where !clone.isReady {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(clone.isReady && onMain.value == false)
    }
}

final class OnMainFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool?

    var value: Bool? {
        lock.withLock { flag }
    }

    func set(_ value: Bool) {
        lock.withLock { flag = value }
    }
}
