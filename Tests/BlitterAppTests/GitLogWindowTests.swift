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
    }, contents: { _, _, _, _ in Data("x".utf8) }, message: { _, hash, _ in
        hash == "aaaa" ? "first" : "Agnus\n\nThe chip that drives the blitter."
    })

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

    /// #89: the selected commit's message, and the whole commit in the diff tool from the button
    /// or Return on the commit.
    @Test func theMessageShowsAndTheWholeCommitGoesToTheDiffTool() async throws {
        let launched = LaunchRecorder()
        workspace.launchTool = { arguments, _ in launched.append(arguments) }
        let controller = GitLogWindowController(workspace: workspace, path: "/repo", access: access)
        controller.showWindow(nil)
        defer { controller.close() }
        try await waitUntil { controller.commitsTable.numberOfRows == 2 }
        #expect(controller.messageView.string.isEmpty && !controller.compareCommitButton.isEnabled)

        controller.commitsTable.selectRowIndexes([0], byExtendingSelection: false)
        try await waitUntil { controller.messageView.string == "Agnus\n\nThe chip that drives the blitter." }
        #expect(controller.compareCommitButton.isEnabled)
        controller.commitsTable.onReturn?()
        try await waitUntil { !launched.calls.isEmpty }
        let call = try #require(launched.calls.first)
        #expect(call.count == 3 && call[1].hasSuffix("/aaaa") && call[2].hasSuffix("/bbbbbbbbbb"))
        #expect(FileManager.default.fileExists(atPath: call[1] + "/old.txt"))
        #expect(FileManager.default.fileExists(atPath: call[2] + "/new.txt"))

        controller.commitsTable.selectRowIndexes([1], byExtendingSelection: false)
        try await waitUntil { controller.messageView.string == "first" }
        controller.compareCommitButton.performClick(nil)
        try await waitUntil { launched.calls.count == 2 }
        #expect(launched.calls.last?[1].hasSuffix("/none") == true)

        controller.commitsTable.deselectAll(nil)
        try await waitUntil { controller.messageView.string.isEmpty }
        #expect(!controller.compareCommitButton.isEnabled)
    }

    /// #89 review: while the commit is written out, the button is off and the status line says
    /// why, at once; when it is done, the diff tool opens and the button is back.
    @Test func preparingACommitShowsAtOnce() async throws {
        let launched = LaunchRecorder()
        workspace.launchTool = { arguments, _ in launched.append(arguments) }
        let gate = Gate()
        let held = GitHistoryAccess(log: access.log, changes: access.changes, contents: { _, _, _, cancelled in
            for _ in 0 ..< 300 where gate.isClosed && !cancelled.isSet {
                Thread.sleep(forTimeInterval: 0.01)
            }
            return Data("x".utf8)
        }, message: access.message)
        let controller = GitLogWindowController(workspace: workspace, path: "/repo", access: held)
        controller.showWindow(nil)
        defer { controller.close() }
        try await waitUntil { controller.commitsTable.numberOfRows == 2 }
        controller.commitsTable.selectRowIndexes([0], byExtendingSelection: false)
        try await waitUntil { controller.changesTable.numberOfRows == 1 && controller.compareCommitButton.isEnabled }
        controller.compareCommitButton.performClick(nil)
        #expect(!controller.compareCommitButton.isEnabled)
        #expect(controller.statusLabel.stringValue == "Writing the commit's files for the diff tool…")
        gate.open()
        try await waitUntil { !launched.calls.isEmpty }
        #expect(launched.calls.count == 1)
        try await waitUntil { controller.compareCommitButton.isEnabled }
        #expect(controller.statusLabel.stringValue == "2 commits")
    }

    /// #91: the lists take the settings' rows when the window opens: lines by default, under real
    /// rows only; stripes are AppKit's.
    @Test func theListsTakeLinesOrStripes() async throws {
        let lined = GitLogWindowController(workspace: workspace, path: "/repo", access: access)
        defer { lined.close() }
        try await waitUntil { lined.commitsTable.numberOfRows == 2 }
        #expect(!lined.commitsTable.usesAlternatingRowBackgroundColors)
        let row = lined.commitsTable.rowView(atRow: 0, makeIfNecessary: true) as? ListRowView
        #expect(row?.drawsLine == true && row?.palette?.isThemed == false)
        lined.log.perform(.select("aaaa"))
        try await waitUntil { lined.changesTable.numberOfRows == 1 }
        #expect(!lined.changesTable.usesAlternatingRowBackgroundColors)
        #expect((lined.changesTable.rowView(atRow: 0, makeIfNecessary: true) as? ListRowView)?.drawsLine == true)

        workspace.settings.theme.rows = .stripes
        let striped = GitLogWindowController(workspace: workspace, path: "/repo", access: access)
        defer { striped.close() }
        try await waitUntil { striped.commitsTable.numberOfRows == 2 }
        #expect(striped.commitsTable.usesAlternatingRowBackgroundColors)
        #expect(striped.changesTable.usesAlternatingRowBackgroundColors)
        #expect(striped.commitsTable.rowView(atRow: 0, makeIfNecessary: true).map { $0 is ListRowView } == false)
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
/// Holds reads back until it is opened.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = true

    var isClosed: Bool {
        lock.withLock { closed }
    }

    func open() {
        lock.withLock { closed = false }
    }
}

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
