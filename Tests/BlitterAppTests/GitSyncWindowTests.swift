import AppKit
@testable import Blitter
@testable import BlitterCore
@testable import BlitterGit
@testable import BlitterModel
import Testing

/// The Git Sync window (#43), with a pretend git: what it shows, which buttons work, and an
/// operation's output and outcome.
@MainActor
@Suite(.serialized)
final class GitSyncWindowTests {
    private let folder: String

    init() throws {
        folder = NSTemporaryDirectory() + "BlitterSyncWindow-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: folder)
    }

    private func controller(upstream: String?, git: String?) -> GitSyncWindowController {
        let workspace = Workspace(initialLocation: "/fake", home: "/home", lister: { _ in [] },
                                  directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory)
        workspace.gitRepositories[folder] = KnownRepository(GitRepoStatus(), checked: Date())
        var status = GitRepoStatus(ahead: 2, behind: 1)
        status.branch = "main"
        status.upstream = upstream
        let access = GitSyncAccess(status: { [status] _, _ in status }, lastFetch: { _, _ in nil }, git: git)
        return GitSyncWindowController(workspace: workspace, path: folder, access: access)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test func itShowsWhereTheBranchStandsAndRunsAnOperation() async throws {
        let script = folder + "/fake-git"
        try "#!/bin/sh\necho \"git $*\"\n".write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        let window = controller(upstream: "origin/main", git: script)
        window.showWindow(nil)
        defer { window.close() }
        try await waitUntil { window.branchLabel.stringValue == "main" }
        #expect(window.upstreamLabel.stringValue == "origin/main")
        #expect(window.stateLabel.stringValue == "2 to push, 1 to pull")
        #expect(window.fetchedLabel.stringValue == "never")
        let allEnabled = window.operationButtons.values.allSatisfy(\.isEnabled)
        #expect(allEnabled)
        #expect(!window.cancelButton.isEnabled)

        try #require(window.operationButtons[.pull]).performClick(nil)
        #expect(!window.operationButtons.values.contains { $0.isEnabled }) // one at a time
        try await waitUntil { window.statusLabel.stringValue == "Pull (rebase) done." }
        #expect(window.outputView.string == "git pull --rebase\n")
        let enabledAgain = window.operationButtons.values.allSatisfy(\.isEnabled)
        #expect(enabledAgain)
    }

    @Test func withoutAnUpstreamOnlyFetchWorks() async throws {
        let window = controller(upstream: nil, git: "/usr/bin/true")
        try await waitUntil { window.branchLabel.stringValue == "main" }
        #expect(window.stateLabel.stringValue == "no upstream: Pull and Push need one")
        #expect(window.operationButtons[.fetch]?.isEnabled == true)
        #expect(window.operationButtons[.pull]?.isEnabled == false && window.operationButtons[.push]?
            .isEnabled == false)
        window.close()
    }
}
