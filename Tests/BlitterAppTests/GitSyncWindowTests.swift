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

    private func controller(upstream: String?, git: String?, rebasing: Bool = false,
                            opened: ((String, [String]) -> Void)? = nil) -> GitSyncWindowController
    {
        let rebasing = Switch(rebasing)
        return controller(upstream: upstream, git: git, rebasing: rebasing, hold: Switch(false), opened: opened)
    }

    /// `rebasing` and `hold` (each state read waits while it is set) can change while it runs.
    private func controller(upstream: String?, git: String?, rebasing: Switch, hold: Switch,
                            opened: ((String, [String]) -> Void)? = nil) -> GitSyncWindowController
    {
        let workspace = Workspace(initialLocation: "/fake", home: "/home", lister: { _ in [] },
                                  directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory)
        workspace.gitRepositories[folder] = KnownRepository(GitRepoStatus(), checked: Date())
        var status = GitRepoStatus(ahead: 2, behind: 1)
        status.branch = "main"
        status.upstream = upstream
        workspace.system.openWithApp = { app, paths, _ in opened?(app, paths) }
        let access = GitSyncAccess(status: { [status] _, cancelled in
            while hold.isOn, !cancelled.isSet {
                Thread.sleep(forTimeInterval: 0.01)
            }
            return status
        }, lastFetch: { _, _ in nil }, rebasing: { _, _ in rebasing.isOn }, git: git)
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
        let allEnabled = GitSync.Operation.syncing.allSatisfy { window.operationButtons[$0]?.isEnabled == true }
        #expect(allEnabled)
        #expect(window.operationButtons[.fetchAndRebase]?.title == "Fetch & Rebase") // #45
        #expect(!window.cancelButton.isEnabled)
        #expect(window.rebaseRow.isHidden && window.operationButtons[.abortRebase]?.isEnabled == false)

        try #require(window.operationButtons[.pull]).performClick(nil)
        #expect(!window.operationButtons.values.contains { $0.isEnabled }) // one at a time
        try await waitUntil { window.statusLabel.stringValue == "Pull (rebase) done." }
        #expect(window.outputView.string == "git pull --rebase\n")
        // Enabled again once the state is read again.
        try await waitUntil { GitSync.Operation.syncing.allSatisfy { window.operationButtons[$0]?.isEnabled == true } }
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

    /// #45: a stopped rebase: nothing but Abort Rebase and Open in Terminal, and it says so.
    @Test func aStoppedRebaseOffersAbortAndTheTerminal() async throws {
        var opened: [(String, [String])] = []
        let window = controller(upstream: "origin/main", git: "/usr/bin/true", rebasing: true) {
            opened.append(($0, $1))
        }
        defer { window.close() }
        try await waitUntil { window.branchLabel.stringValue == "main" && !window.rebaseRow.isHidden }
        let noneEnabled = GitSync.Operation.syncing.allSatisfy { window.operationButtons[$0]?.isEnabled == false }
        #expect(noneEnabled)
        #expect(window.operationButtons[.abortRebase]?.isEnabled == true && window.terminalButton.isEnabled)
        #expect(window.statusLabel.stringValue.hasPrefix("A rebase has stopped"))
        window.terminalButton.performClick(nil)
        #expect(opened.count == 1 && opened.first?.0 == "iTerm" && opened.first?.1 == [window.sync.root ?? ""])
    }

    /// #45 review: the buttons stay off until the state after an operation is read.
    @Test func theButtonsWaitForTheStateAfterAnOperation() async throws {
        let hold = Switch(false)
        let window = controller(upstream: "origin/main", git: "/usr/bin/false", rebasing: Switch(false), hold: hold)
        defer { window.close() }
        try await waitUntil { window.operationButtons[.fetchAndRebase]?.isEnabled == true }
        hold.set(true)
        try #require(window.operationButtons[.fetchAndRebase]).performClick(nil)
        try await waitUntil { window.sync.running == nil }
        let noneEnabled = GitSync.Operation.allCases.allSatisfy { window.operationButtons[$0]?.isEnabled == false }
        #expect(noneEnabled)
        hold.set(false)
        try await waitUntil { window.operationButtons[.fetchAndRebase]?.isEnabled == true }
    }

    /// #45 review: a rebase finished in the terminal shows when the window is back in front.
    @Test func aRebaseFinishedInTheTerminalShowsOnReturn() async throws {
        let rebasing = Switch(true)
        let window = controller(upstream: "origin/main", git: "/usr/bin/true", rebasing: rebasing, hold: Switch(false))
        defer { window.close() }
        try await waitUntil { !window.rebaseRow.isHidden }
        rebasing.set(false) // done there
        window.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        try await waitUntil {
            window.rebaseRow.isHidden && GitSync.Operation.syncing.allSatisfy {
                window.operationButtons[$0]?.isEnabled == true
            }
        }
        #expect(!window.statusLabel.stringValue.hasPrefix("A rebase"))
    }
}

/// On or off, shared with the pretend git's closures while the test changes it.
private final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var state: Bool

    init(_ state: Bool) {
        self.state = state
    }

    var isOn: Bool {
        lock.withLock { state }
    }

    func set(_ value: Bool) {
        lock.withLock { state = value }
    }
}
