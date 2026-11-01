import AppKit
@testable import Blitter
@testable import BlitterCore
@testable import BlitterModel
import Testing

/// File operations driven through the real views, on real temporary folders. The jobs use a
/// Trash folder of their own.
@MainActor
@Suite(.serialized)
final class FileOperationsInteractionTests {
    private let root = NSTemporaryDirectory() + "BlitterAppTests-" + UUID().uuidString
    private let workspace: Workspace
    private let fileList: FileListViewController
    private let jobsStrip: JobsViewController
    private let window: NSWindow

    init() async throws {
        let left = root + "/left"
        let right = root + "/right"
        let trash = root + "/trash"
        for folder in [left, right, trash] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: left + "/report.txt", contents: Data("r".utf8))
        let jobs = JobQueue(trash: { path in
            try FileManager.default.moveItem(atPath: path, toPath: trash + "/" + (path as NSString).lastPathComponent)
        })
        workspace = Workspace(initialLocation: left, home: root + "/home", directoryCheck: { _ in false },
                              volumes: { [] }, watcher: FakeWatcher.factory, jobs: jobs)
        workspace.perform(.navigate(.right, path: right))
        fileList = FileListViewController(workspace: workspace, side: .left)
        jobsStrip = JobsViewController(workspace: workspace)
        let content = NSViewController()
        let stack = NSStackView(views: [fileList.view, jobsStrip.view])
        stack.orientation = .vertical
        content.view = stack
        content.addChild(fileList)
        content.addChild(jobsStrip)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 500),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = content
        window.setContentSize(NSSize(width: 700, height: 500))
        workspace.onChange = { [fileList, jobsStrip] in
            fileList.render()
            jobsStrip.render()
        }
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { self.names() == ["report.txt"] }
    }

    isolated deinit {
        window.close()
        try? FileManager.default.removeItem(atPath: root)
    }

    // MARK: Menu

    @Test func theFileMenuHasTheOperationShortcuts() throws {
        func key(_ function: Int) throws -> String {
            try String(Character(#require(UnicodeScalar(UInt16(function)))))
        }
        let menu = try #require(NSApp.mainMenu?.items.first { $0.submenu?.title == "File" }?.submenu)
        let items = Dictionary(uniqueKeysWithValues: menu.items.filter { !$0.isSeparatorItem }.map { ($0.title, $0) })
        #expect(items["New Folder"]?.keyEquivalent == "n")
        #expect(items["New Folder"]?.keyEquivalentModifierMask == [.command, .shift])
        #expect(try items["Rename"]?.keyEquivalent == key(NSF2FunctionKey))
        #expect(try items["Copy to Other Side"]?.keyEquivalent == key(NSF5FunctionKey))
        #expect(try items["Move to Other Side"]?.keyEquivalent == key(NSF6FunctionKey))
        #expect(items["Move to Trash"]?.keyEquivalent == "\u{8}")
        #expect(items["Move to Trash"]?.keyEquivalentModifierMask == .command)
        #expect(items.values.allSatisfy { $0.target is AppDelegate })
    }

    // MARK: Inline rename

    @Test func renamingInPlaceSelectsTheNameAndCommitsOnReturn() async throws {
        workspace.perform(.select(.left, ["report.txt"]))
        workspace.perform(.requestRename(.left))
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.string == "report.txt")
        #expect(editor.selectedRange() == NSRange(location: 0, length: 6)) // "report", not ".txt"

        editor.insertText("final", replacementRange: editor.selectedRange())
        editor.keyDown(with: key("\r", code: 36))
        try await waitUntil { self.names() == ["final.txt"] }
        #expect(FileManager.default.fileExists(atPath: root + "/left/final.txt"))
        #expect(workspace.state(of: .left).selection == ["final.txt"])
        #expect(window.firstResponder === tableView)
    }

    @Test func escapeCancelsTheRename() async throws {
        workspace.perform(.select(.left, ["report.txt"]))
        workspace.perform(.requestRename(.left))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("other", replacementRange: editor.selectedRange())
        editor.keyDown(with: key("\u{1b}", code: 53))
        try await waitUntil { self.workspace.state(of: .left).renameRequest == nil }
        try await Task.sleep(for: .milliseconds(100))
        #expect(FileManager.default.fileExists(atPath: root + "/left/report.txt"))
        #expect(workspace.jobs.isEmpty)
        let cell = tableView.view(atColumn: 0, row: 0, makeIfNecessary: false) as? NSTableCellView
        #expect(cell?.textField?.stringValue == "report.txt")
        #expect(cell?.textField?.isEditable == false)
    }

    /// Navigating while a name is edited ends the edit; the commit renames the item that was
    /// being edited, never the same-named item in the folder the side shows now.
    @Test func navigatingDuringAnEditRenamesTheEditedItemOnly() async throws {
        FileManager.default.createFile(atPath: root + "/right/report.txt", contents: Data("other".utf8))
        workspace.perform(.select(.left, ["report.txt"]))
        workspace.perform(.requestRename(.left))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("edited", replacementRange: editor.selectedRange())

        workspace.perform(.navigate(.left, path: root + "/right"))
        try await waitUntil { FileManager.default.fileExists(atPath: self.root + "/left/edited.txt") }
        #expect(FileManager.default.fileExists(atPath: root + "/right/report.txt"))
        #expect(!FileManager.default.fileExists(atPath: root + "/right/edited.txt"))
        #expect(workspace.state(of: .left).renameRequest == nil)
    }

    @Test func aNewFolderStartsWithItsNameBeingEdited() async throws {
        workspace.perform(.newFolder(.left))
        // The path field's editor may have focus at first; wait for the new folder's name.
        try await waitUntil { (self.window.firstResponder as? NSTextView)?.string == "New Folder" }
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.string == "New Folder")
        #expect(names().contains("New Folder"))
    }

    // MARK: Jobs strip

    @Test func aConflictIsAnsweredWithTheButtonsInTheStrip() async throws {
        FileManager.default.createFile(atPath: root + "/right/report.txt", contents: Data("old".utf8))
        workspace.perform(.select(.left, ["report.txt"]))
        workspace.perform(.copyToOtherSide)
        try await waitUntil { self.button("Keep Both") != nil }
        #expect(!jobsStrip.view.isHidden)
        #expect(texts().contains("“report.txt” already exists in “right”."))

        try #require(button("Keep Both")).performClick(nil)
        try await waitUntil { self.workspace.jobs.isEmpty }
        let copied = try FileManager.default.contentsOfDirectory(atPath: root + "/right").sorted()
        #expect(copied == ["report 2.txt", "report.txt"])
        #expect(jobsStrip.view.isHidden)
    }

    @Test func aJobWithProblemsStaysUntilDismissed() async throws {
        workspace.perform(.rename(.left, path: root + "/left/report.txt", newName: "a/b"))
        try await waitUntil { self.button("Dismiss") != nil }
        #expect(texts().contains { $0.contains("is not a valid name") })
        try #require(button("Dismiss")).performClick(nil)
        #expect(workspace.jobs.isEmpty)
        #expect(jobsStrip.view.isHidden)
    }

    @Test func theAppMenuOpensTheSettings() throws {
        let appMenu = try #require(NSApp.mainMenu?.items.first?.submenu)
        let item = try #require(appMenu.items.first { $0.title == "Settings…" })
        #expect(item.keyEquivalent == "," && item.keyEquivalentModifierMask == .command)
        #expect(item.target is AppDelegate)
    }

    /// #16: Copy Path and Copy Name run their actions from the registry on the active side.
    @Test func theEditMenuCopiesPathsAndNames() throws {
        let editMenu = try #require(NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "Edit" })
        let path = try #require(editMenu.items.first { $0.title == "Copy Path" })
        let name = try #require(editMenu.items.first { $0.title == "Copy Name" })
        #expect(path.keyEquivalent == "c" && path.keyEquivalentModifierMask == [.command, .option])
        #expect(name.keyEquivalent == "c" && name.keyEquivalentModifierMask == [.command, .option, .shift])
        #expect(path.representedObject as? String == "copy-path" && name.representedObject as? String == "copy-name")
        #expect(path.target is AppDelegate && name.target is AppDelegate)
        // Validation asks the registry: the test host's workspace has nothing selected.
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        #expect(!delegate.validateMenuItem(path) && !delegate.validateMenuItem(name))
    }

    @Test func aNoticeShowsInTheStripUntilDismissed() throws {
        workspace.addNotice("Settings file: something is off.")
        workspace.onChange?()
        #expect(!jobsStrip.view.isHidden)
        #expect(texts().contains("Settings file: something is off."))
        try #require(button("Dismiss")).performClick(nil)
        #expect(workspace.notices.isEmpty)
        #expect(jobsStrip.view.isHidden)
    }

    @Test func jobTextDescribesOperationsAndProgress() {
        #expect(JobText.title(.copy(["/a/x.txt"], into: "/b")) == "Copying “x.txt” to “b”")
        #expect(JobText.title(.move(["/a/x", "/a/y"], into: "/b")) == "Moving 2 items to “b”")
        #expect(JobText.title(.trash(["/a/x"])) == "Moving “x” to the Trash")
        var progress = JobProgress()
        #expect(JobText.fraction(progress) == nil)
        progress.totalItems = 4
        progress.doneItems = 1
        #expect(JobText.fraction(progress) == 0.25)
        progress.totalBytes = 200
        progress.doneBytes = 150
        #expect(JobText.fraction(progress) == 0.75)
    }

    // MARK: Helpers

    private var tableView: NSTableView {
        // swiftlint:disable:next force_cast
        (fileList.view.subviews.first { $0 is NSScrollView } as! NSScrollView).documentView as! NSTableView
    }

    private func names() -> [String] {
        workspace.state(of: .left).visibleEntries.map(\.entry.name)
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }

    private func button(_ title: String) -> NSButton? {
        allSubviews(of: jobsStrip.view).compactMap { $0 as? NSButton }.first { $0.title == title }
    }

    private func texts() -> [String] {
        allSubviews(of: jobsStrip.view).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private func key(_ characters: String, code: UInt16) -> NSEvent {
        // swiftlint:disable:next force_unwrapping
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
