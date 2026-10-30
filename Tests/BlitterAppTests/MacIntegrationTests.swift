import AppKit
@testable import Blitter
@testable import BlitterCore
@testable import BlitterModel
import Quartz
import Testing

struct DropRulesTests {
    private let all: NSDragOperation = [.copy, .move, .generic, .link]

    @Test func movesByDefaultAndCopiesWithOption() {
        #expect(DropRules.operation(for: all, sources: ["/a/x"], into: "/b") == .move) // a plain drag
        #expect(DropRules.operation(for: .copy, sources: ["/a/x"], into: "/b") == .copy) // ⌥ held
        #expect(DropRules.operation(for: .move, sources: ["/a/x"], into: "/b") == .move) // ⌘ held
        #expect(DropRules.operation(for: .generic, sources: ["/a/x"], into: "/b") == .move) // ⌘, older systems
        #expect(DropRules.operation(for: [.copy, .link], sources: ["/a/x"], into: "/b") == .copy) // copy only
        #expect(DropRules.operation(for: .link, sources: ["/a/x"], into: "/b") == [])
    }

    @Test func dropsThatWouldDoNothingOrHarmAreRefused() {
        #expect(DropRules.operation(for: all, sources: ["/a/x"], into: "/a") == []) // its own folder
        #expect(DropRules.operation(for: all, sources: ["/a/x"], into: "/a/x") == []) // onto itself
        #expect(DropRules.operation(for: all, sources: ["/a/x"], into: "/a/x/sub") == []) // into itself
        #expect(DropRules.operation(for: all, sources: [], into: "/b") == [])
    }
}

/// A drop as AppKit hands it to the table: a pasteboard and the operations the drag allows.
@MainActor
final class FakeDrop: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSourceOperationMask: NSDragOperation

    init(_ paths: [String], allowed: NSDragOperation) {
        draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("Blitter.drop." + UUID().uuidString))
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
        draggingSourceOperationMask = allowed
    }

    isolated deinit {
        draggingPasteboard.releaseGlobally()
    }

    var draggingDestinationWindow: NSWindow? {
        nil
    }

    var draggingLocation: NSPoint {
        .zero
    }

    var draggedImageLocation: NSPoint {
        .zero
    }

    var draggedImage: NSImage? {
        nil
    }

    var draggingSource: Any? {
        nil
    }

    var draggingSequenceNumber: Int {
        1
    }

    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight {
        .none
    }

    func slideDraggedImage(to _: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options _: NSDraggingItemEnumerationOptions = [], for _: NSView?,
                                classes _: [AnyClass], searchOptions _: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using _: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

/// Quick Look, opening, drag and drop and Reveal in Finder, through the real file list on real
/// temporary folders.
@MainActor
@Suite(.serialized)
final class MacIntegrationTests {
    private let root = NSTemporaryDirectory() + "BlitterMacTests-" + UUID().uuidString
    private let workspace: Workspace
    private let list: FileListViewController
    private let window: NSWindow

    init() async throws {
        for folder in ["left/sub", "right", "outside"] {
            try FileManager.default.createDirectory(atPath: root + "/" + folder, withIntermediateDirectories: true)
        }
        for path in ["left/a.txt", "outside/dropped.txt"] {
            FileManager.default.createFile(atPath: root + "/" + path, contents: Data(path.utf8))
        }
        workspace = Workspace(initialLocation: root + "/left", home: root + "/home", directoryCheck: { _ in false },
                              volumes: { [] }, watcher: FakeWatcher.factory,
                              jobs: JobQueue(trash: { _ in throw POSIXError(.EPERM) }))
        list = FileListViewController(workspace: workspace, side: .left)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 400),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = list
        window.setContentSize(NSSize(width: 700, height: 400))
        workspace.onChange = { [list] in list.render() }
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { self.names() == ["sub", "a.txt"] }
    }

    isolated deinit {
        if QLPreviewPanel.sharedPreviewPanelExists() {
            QLPreviewPanel.shared()?.orderOut(nil)
        }
        window.close()
        try? FileManager.default.removeItem(atPath: root)
    }

    // MARK: Drag and drop

    @Test func rowsAreDraggedAsFileURLsWithTheFolderFlagFromTheListing() throws {
        let folder = try #require(list.tableView(list.tableView, pasteboardWriterForRow: 0) as? NSURL)
        let file = try #require(list.tableView(list.tableView, pasteboardWriterForRow: 1) as? NSURL)
        #expect(folder.path == root + "/left/sub" && folder.hasDirectoryPath)
        #expect(file.path == root + "/left/a.txt" && !file.hasDirectoryPath)
    }

    @Test func aPlainDropMovesIntoTheSidesFolder() async throws {
        let drop = FakeDrop([root + "/outside/dropped.txt"], allowed: [.copy, .move, .generic])
        let operation = list.tableView(
            list.tableView,
            validateDrop: drop,
            proposedRow: 5,
            proposedDropOperation: .above
        )
        #expect(operation == .move)
        #expect(list.tableView(list.tableView, acceptDrop: drop, row: 5, dropOperation: .above))
        try await waitUntil { self.names() == ["sub", "a.txt", "dropped.txt"] }
        #expect(!FileManager.default.fileExists(atPath: root + "/outside/dropped.txt"))
    }

    @Test func aDropWithOptionCopiesIntoTheFolderRowUnderThePointer() async throws {
        let drop = FakeDrop([root + "/outside/dropped.txt"], allowed: .copy)
        #expect(list.tableView(list.tableView, acceptDrop: drop, row: 0, dropOperation: .on)) // row 0 is "sub"
        try await waitUntil {
            FileManager.default.fileExists(atPath: self.root + "/left/sub/dropped.txt")
        }
        #expect(FileManager.default.fileExists(atPath: root + "/outside/dropped.txt")) // a copy
    }

    @Test func droppingItemsOnTheirOwnFolderIsRefused() {
        let drop = FakeDrop([root + "/left/a.txt"], allowed: [.copy, .move, .generic])
        #expect(list.tableView(list.tableView, validateDrop: drop, proposedRow: 1, proposedDropOperation: .above) == [])
        #expect(!list.tableView(list.tableView, acceptDrop: drop, row: 1, dropOperation: .above))
    }

    // MARK: Quick Look, open, reveal

    @Test func quickLookShowsTheSelection() throws {
        workspace.perform(.select(.left, ["a.txt"]))
        #expect(list.acceptsPreviewPanelControl(nil))
        #expect(list.numberOfPreviewItems(in: nil) == 1)
        let item = try #require(list.previewPanel(nil, previewItemAt: 0) as? URL)
        #expect(item.path == root + "/left/a.txt")
    }

    @Test func spaceTogglesQuickLookThroughItsCommand() {
        var previews: [Side] = []
        workspace.system.togglePreview = { previews.append($0) }
        list.tableView.keyDown(with: key(" ", code: 49))
        #expect(previews == [.left])
    }

    /// The preview follows the selection whatever changed it, not only a click in the list.
    @Test func anOpenPreviewFollowsSelectionChangesTheModelMakes() async throws {
        var reloads = 0
        list.previewItemsChanged = { reloads += 1 }
        workspace.perform(.open(.left, name: "sub"))
        try await waitUntil { self.workspace.state(of: .left).entriesLocation == self.root + "/left/sub" }
        reloads = 0

        workspace.perform(.goToParent(.left)) // the listing arrives and selects "sub" by itself
        try await waitUntil { self.workspace.state(of: .left).selection == ["sub"] }
        #expect(reloads == 1)
        let item = try #require(list.previewPanel(nil, previewItemAt: 0) as? URL)
        #expect(item.path == root + "/left/sub")

        workspace.perform(.activate(.right)) // a render that changes no selection
        #expect(reloads == 1)
    }

    @Test func revealInFinderIsInTheFileMenu() throws {
        let menu = try #require(NSApp.mainMenu?.items.first { $0.submenu?.title == "File" }?.submenu)
        let item = try #require(menu.items.first { $0.title == "Reveal in Finder" })
        #expect(item.keyEquivalent == "r" && item.keyEquivalentModifierMask == [.command, .option])
        #expect(item.target is AppDelegate)
    }

    // MARK: Helpers

    private func names() -> [String] {
        workspace.state(of: .left).visibleEntries.map(\.entry.name)
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
