import AppKit
@testable import Blitter
@testable import BlitterCore
@testable import BlitterModel
import Testing

/// Copy and paste of files through a private pasteboard: the user's clipboard is never touched.
@MainActor
@Suite(.serialized)
final class PasteboardInteractionTests {
    private let root = NSTemporaryDirectory() + "BlitterPasteTests-" + UUID().uuidString
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("Blitter.tests." + UUID().uuidString))
    private let general = NSPasteboard.general.changeCount
    private let workspace: Workspace
    private let left: FileListViewController
    private let right: FileListViewController
    private let window: NSWindow

    init() async throws {
        for folder in ["left", "right", "outside"] {
            try FileManager.default.createDirectory(atPath: root + "/" + folder, withIntermediateDirectories: true)
        }
        for name in ["a.txt", "b.txt"] {
            FileManager.default.createFile(atPath: root + "/left/" + name, contents: Data(name.utf8))
        }
        workspace = Workspace(initialLocation: root + "/left", home: root + "/home", directoryCheck: { _ in false },
                              volumes: { [] }, watcher: FakeWatcher.factory,
                              jobs: JobQueue(trash: { _ in throw POSIXError(.EPERM) }))
        workspace.perform(.navigate(.right, path: root + "/right"))
        left = FileListViewController(workspace: workspace, side: .left)
        right = FileListViewController(workspace: workspace, side: .right)
        left.pasteboard = pasteboard
        right.pasteboard = pasteboard
        let content = NSViewController()
        let stack = NSStackView(views: [left.view, right.view])
        content.view = stack
        content.addChild(left)
        content.addChild(right)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 400),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = content
        workspace.onChange = { [left, right] in
            left.render()
            right.render()
        }
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { self.names(.left) == ["a.txt", "b.txt"] }
    }

    isolated deinit {
        window.close()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(atPath: root)
    }

    @Test func copyPutsTheSelectedFilesOnThePasteboardAsFinderDoes() async throws {
        try FileManager.default.createDirectory(atPath: root + "/left/folder", withIntermediateDirectories: false)
        workspace.perform(.refresh(.left))
        try await waitUntil { self.names(.left).contains("folder") }
        workspace.perform(.select(.left, ["a.txt", "b.txt", "folder"]))
        left.copy(nil)
        #expect(pasteboard.types?.contains(.fileURL) == true) // what Finder reads
        let urls = try #require(pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])
        #expect(urls.map(\.lastPathComponent) == ["folder", "a.txt", "b.txt"]) // in list order
        #expect(urls.map(\.hasDirectoryPath) == [true, false, false]) // from the listing, not the disk
        let allAreFileURLs = urls.allSatisfy(\.isFileURL)
        #expect(allAreFileURLs)
        #expect(NSPasteboard.general.changeCount == general)
    }

    @Test func pasteCopiesFilesFromThePasteboardIntoTheSide() async throws {
        // As Finder puts them there: one file URL per item.
        let outside = root + "/outside/from-finder.txt"
        FileManager.default.createFile(atPath: outside, contents: Data("f".utf8))
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: outside) as NSURL])

        right.paste(nil)
        try await waitUntil { self.names(.right) == ["from-finder.txt"] }
        #expect(FileManager.default.fileExists(atPath: outside)) // a copy
    }

    @Test func moveItemHereMovesThem() async throws {
        let outside = root + "/outside/moved.txt"
        FileManager.default.createFile(atPath: outside, contents: Data("m".utf8))
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: outside) as NSURL])

        right.moveItemsHere(nil)
        try await waitUntil { self.names(.right) == ["moved.txt"] }
        #expect(!FileManager.default.fileExists(atPath: outside))
    }

    @Test func copyThenPasteOnTheOtherSideThroughTheMenu() async throws {
        workspace.perform(.select(.left, ["b.txt"]))
        try perform("Copy", in: left)
        try perform("Paste", in: right)
        try await waitUntil { self.names(.right) == ["b.txt"] }
        #expect(names(.left) == ["a.txt", "b.txt"])
    }

    @Test func menuItemsAreOnlyEnabledWhenTheyCanDoSomething() throws {
        let copy = try #require(menuItem("Copy"))
        let paste = try #require(menuItem("Paste"))
        let moveHere = try #require(menuItem("Move Item Here"))
        #expect(moveHere.keyEquivalent == "v" && moveHere.keyEquivalentModifierMask == [.command, .option])

        pasteboard.clearContents()
        pasteboard.setString("just text", forType: .string)
        workspace.perform(.select(.left, []))
        #expect(!left.validateMenuItem(copy))
        #expect(!left.validateMenuItem(paste))
        #expect(!left.validateMenuItem(moveHere))

        workspace.perform(.select(.left, ["a.txt"]))
        #expect(left.validateMenuItem(copy))
        left.copy(nil)
        #expect(right.validateMenuItem(paste) && right.validateMenuItem(moveHere))
    }

    // MARK: Helpers

    private func names(_ side: Side) -> [String] {
        workspace.state(of: side).visibleEntries.map(\.entry.name)
    }

    private func menuItem(_ title: String) -> NSMenuItem? {
        NSApp.mainMenu?.items.first { $0.submenu?.title == "Edit" }?.submenu?.items.first { $0.title == title }
    }

    /// The app's own Edit menu item, delivered to the list's table view as the first responder,
    /// from where the responder chain reaches the controller (as AppKit does for the key window).
    private func perform(_ title: String, in controller: FileListViewController) throws {
        let item = try #require(menuItem(title))
        let action = try #require(item.action)
        let table = try #require(controller.view.subviews.compactMap { $0 as? NSScrollView }.first?.documentView)
        window.makeFirstResponder(table)
        #expect(item.target == nil)
        #expect(NSApp.sendAction(action, to: nil, from: item) || table.tryToPerform(action, with: item))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
