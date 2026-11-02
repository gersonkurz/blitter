import AppKit
@testable import Blitter
@testable import BlitterCore
@testable import BlitterGit
@testable import BlitterModel
import Testing

/// The Git Log window (#42), with a pretend git: the commits, the filter, the changes of the
/// selected commit, and the diff tool on a double-click. And the dialog host that opens it.
@MainActor
@Suite(.serialized)
final class GitLogWindowTests {
    private let workspace: Workspace
    private var launched: [[String]] = []

    init() {
        workspace = Workspace(initialLocation: "/fake", home: "/home", lister: { _ in [] },
                              directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory)
        workspace.gitRepositories["/repo"] = KnownRepository(GitRepoStatus(), checked: Date())
        workspace.findDiffTool = { DiffTool(["tool", "{left}", "{right}"]) }
    }

    private let access = GitHistoryAccess(log: { _, _, _ in
        [GitCommit(hash: "bbbbbbbbbbbb", parent: "aaaa", author: "Jay Miner", date: Date(timeIntervalSince1970: 0),
                   subject: "Agnus"),
         GitCommit(hash: "aaaa", parent: nil, author: "Grace Hopper", date: Date(timeIntervalSince1970: 0),
                   subject: "first")]
    }, changes: { _, commit, _ in
        commit.hash == "aaaa" ? [GitChange(status: "A", path: "a.txt")]
            : [GitChange(status: "R", path: "new.txt", oldPath: "old.txt")]
    }, contents: { _, _, _, _ in Data("x".utf8) })

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    private func text(_ table: NSTableView, row: Int, column: Int) -> String? {
        (table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
    }

    @Test func itListsFiltersAndShowsAChangeInTheDiffTool() async throws {
        let launched = LaunchRecorder()
        workspace.launchTool = { arguments, _ in launched.append(arguments) }
        let controller = GitLogWindowController(workspace: workspace, path: "/repo/src", access: access)
        controller.showWindow(nil)
        defer { controller.close() }
        #expect(controller.window?.title == "Git Log — src")
        try await waitUntil { controller.commitsTable.numberOfRows == 2 }
        #expect(text(controller.commitsTable, row: 0, column: 0) == "Agnus")
        #expect(text(controller.commitsTable, row: 0, column: 3) == "bbbbbbbbbb") // ten characters
        #expect(controller.statusLabel.stringValue == "2 commits")

        controller.filterField.stringValue = "hopper"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        try await waitUntil { controller.commitsTable.numberOfRows == 1 }
        #expect(text(controller.commitsTable, row: 0, column: 0) == "first")
        #expect(controller.statusLabel.stringValue == "1 of 2 commits")
        controller.filterField.stringValue = ""
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        try await waitUntil { controller.commitsTable.numberOfRows == 2 }

        controller.commitsTable.selectRowIndexes([0], byExtendingSelection: false)
        try await waitUntil { controller.changesTable.numberOfRows == 1 }
        #expect(text(controller.changesTable, row: 0, column: 1) == "old.txt → new.txt")
        #expect(try #require(controller.changesTable.tableColumns.first).width < 60) // the file gets the room

        controller.changesTable.selectRowIndexes([0], byExtendingSelection: false)
        controller.changesTable.onReturn?()
        try await waitUntil { !launched.calls.isEmpty }
        #expect(launched.calls.first?.first == "tool")
        #expect(launched.calls.first?.last?.hasSuffix("/bbbbbbbbbb/new.txt") == true)
    }

    @Test func theHostOpensARegisteredKindAndForgetsItWhenClosed() throws {
        DialogHost.present(DialogRequest(kind: "no-such-kind", path: "/repo")) // nothing registered
        let before = DialogHost.open.count
        DialogHost.register("test-log") { [workspace, access] request in
            GitLogWindowController(workspace: workspace, path: request.path, access: access)
        }
        weak var closedController: NSWindowController?
        weak var closedLog: GitLog?
        try autoreleasepool {
            DialogHost.present(DialogRequest(kind: "test-log", path: "/repo"))
            #expect(DialogHost.open.count == before + 1)
            let controller = try #require(DialogHost.open.last as? GitLogWindowController)
            let window = try #require(controller.window)
            #expect(window.isVisible && window.title == "Git Log — repo")
            closedController = controller
            closedLog = controller.log
            window.close()
        }
        #expect(DialogHost.open.count == before)
        // #42 review: nothing keeps a closed window, or its history, alive.
        for _ in 0 ..< 100 where closedController != nil || closedLog != nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        #expect(closedController == nil)
        #expect(closedLog == nil)
    }
}

/// Collects launched command lines from any thread.
final class LaunchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String]] = []

    var calls: [[String]] {
        lock.withLock { stored }
    }

    func append(_ arguments: [String]) {
        lock.withLock { stored.append(arguments) }
    }
}
