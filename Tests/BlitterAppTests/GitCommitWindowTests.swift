import AppKit
@testable import Blitter
@testable import BlitterCore
@testable import BlitterGit
@testable import BlitterModel
import Testing

/// The Git Commit window (#44), with a pretend git: the files and their checkboxes, when the
/// buttons work, an earlier message, and a commit's outcome.
@MainActor
@Suite(.serialized)
final class GitCommitWindowTests {
    private let folder: String

    init() throws {
        folder = NSTemporaryDirectory() + "BlitterCommitWindow-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: folder)
    }

    /// `commitTakes`: how long the pretend git's commit step takes, in seconds.
    private func controller(upstream: String?, commitTakes: Double = 0) throws -> GitCommitWindowController {
        let script = folder + "/fake-git"
        try "#!/bin/sh\n[ \"$2\" = commit ] && sleep \(commitTakes)\necho \"git $1 $2\"\n"
            .write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        let workspace = Workspace(initialLocation: "/fake", home: "/home", lister: { _ in [] },
                                  directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory)
        workspace.gitRepositories[folder] = KnownRepository(GitRepoStatus(), checked: Date())
        let changes = GitWorkingChanges(branch: "main", upstream: upstream, files: [
            GitFileChange(path: "staged.txt", staged: "M"),
            GitFileChange(path: "src/changed.swift", unstaged: "M"),
            GitFileChange(path: "new.txt", unstaged: "?"),
            GitFileChange(path: "docs/new.md", oldPath: "docs/old.md", staged: "R"),
            GitFileChange(path: "kept.txt", staged: "D", unstaged: "?"), // `git rm --cached`
        ])
        let access = GitCommitAccess(changes: { _, _ in changes },
                                     messages: { _, _ in ["Fix the copper list\n\nWith a body", "Same title",
                                                          "Same title"] },
                                     contents: { _, _, _, _ in Data() }, git: script)
        return GitCommitWindowController(workspace: workspace, path: folder, access: access)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    private func checkbox(_ window: GitCommitWindowController, row: Int) throws -> NSButton {
        try #require(window.filesTable.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSButton)
    }

    private func type(_ text: String, in window: GitCommitWindowController) {
        window.messageView.string = text
        window.textDidChange(Notification(name: NSText.didChangeNotification))
    }

    @Test func filesAreCheckedAndACommitNeedsAMessage() async throws {
        let window = try controller(upstream: nil)
        window.showWindow(nil)
        defer { window.close() }
        try await waitUntil { window.renderedFiles.count == 5 }
        #expect(window.branchLabel.stringValue == "main (no upstream)")
        let states = try (0 ..< 5).map { try checkbox(window, row: $0).state }
        #expect(states == [.on, .off, .off, .on, .on]) // the staged ones
        let letters = (0 ..< 5).map {
            (window.filesTable.view(atColumn: 1, row: $0, makeIfNecessary: true) as? NSTableCellView)?
                .textField?.stringValue
        }
        #expect(letters == ["M ", " M", "??", "R ", "D?"]) // the staged deletion is not hidden
        let renamed = window.filesTable.view(atColumn: 2, row: 3, makeIfNecessary: true) as? NSTableCellView
        #expect(renamed?.textField?.stringValue == "docs/old.md → docs/new.md")
        #expect(window.statusLabel.stringValue == "3 of 5 files checked")
        #expect(!window.commitButton.isEnabled && !window.commitPushButton.isEnabled)

        type("A message", in: window)
        #expect(window.commitButton.isEnabled)
        #expect(!window.commitPushButton.isEnabled) // nothing to push to

        let box = try checkbox(window, row: 2)
        box.performClick(nil) // the untracked one
        #expect(window.committer.checked == ["staged.txt", "new.txt", "docs/new.md", "kept.txt"])
        window.filesTable.selectRowIndexes([1, 2], byExtendingSelection: false)
        window.filesTable.onSpace?() // not all checked: checks them
        #expect(window.committer.checked.count == 5)
        #expect(window.filesTable.selectedRowIndexes == [1, 2])
        window.filesTable.onSpace?() // all checked: unchecks them
        #expect(window.committer.checked == ["staged.txt", "docs/new.md", "kept.txt"])
        #expect(try checkbox(window, row: 1).state == .off)
        try #require(window.window?.contentView?.firstSubview(titled: "Uncheck All")).performClick(nil)
        #expect(window.committer.checked.isEmpty && !window.commitButton.isEnabled)
    }

    @Test func anEarlierMessageAndACommitAndPush() async throws {
        let window = try controller(upstream: "origin/main")
        window.showWindow(nil)
        defer { window.close() }
        try await waitUntil { window.recentMenu.numberOfItems == 4 }
        // Two messages with the same title stay two items.
        #expect(window.recentMenu.itemTitles == ["Recent Messages", "Fix the copper list", "Same title",
                                                 "Same title"])
        window.recentMenu.menu?.performActionForItem(at: 1)
        #expect(window.messageView.string == "Fix the copper list\n\nWith a body")
        #expect(window.commitPushButton.isEnabled)

        window.commitPushButton.performClick(nil)
        #expect(!window.commitButton.isEnabled && window.cancelButton.isEnabled)
        try await waitUntil { window.statusLabel.stringValue == "Committed and pushed." }
        // The staged ones are checked; "kept.txt" is on disk again (untracked): added first.
        #expect(window.outputView.string
            == "git --literal-pathspecs add\ngit --literal-pathspecs commit\ngit push \n")
        #expect(window.messageView.string.isEmpty) // done with it
    }

    /// #44 review: while a commit runs, its message cannot be changed; one written in the
    /// meantime anyway (here: set directly) is not cleared when the commit is done.
    @Test func theMessageIsLockedWhileCommittingAndANewOneIsKept() async throws {
        let window = try controller(upstream: nil, commitTakes: 0.5)
        window.showWindow(nil)
        defer { window.close() }
        try await waitUntil { window.renderedFiles.count == 5 && window.recentMenu.isEnabled }
        type("First", in: window)
        #expect(window.messageView.isEditable)
        window.commitButton.performClick(nil)
        #expect(!window.messageView.isEditable && !window.recentMenu.isEnabled)
        window.messageView.string = "The next one"
        try await waitUntil { window.statusLabel.stringValue == "Committed." }
        #expect(window.messageView.string == "The next one")
        #expect(window.messageView.isEditable && window.recentMenu.isEnabled)
    }
}

private extension NSView {
    func firstSubview(titled title: String) -> NSButton? {
        for view in subviews {
            if let button = view as? NSButton, button.title == title {
                return button
            }
            if let found = view.firstSubview(titled: title) {
                return found
            }
        }
        return nil
    }
}
