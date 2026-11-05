import AppKit
@testable import Blitter
import BlitterCore
@testable import BlitterModel
import Testing

/// #62: the file list and the folder tree draw with the settings' fonts, rows as high as they need.
@MainActor
@Suite(.serialized)
final class ListFontsTests {
    private let workspace: Workspace
    private let controller: FileListViewController
    private let tree: FolderTreeViewController
    private let window: NSWindow

    init() async throws {
        let entries = [file("notes.txt"), folder("docs")]
        workspace = Workspace(initialLocation: "/home", home: "/home", lister: { _ in entries },
                              directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory)
        workspace.settings.columns = [.name, .size, .modified, .permissions]
        controller = FileListViewController(workspace: workspace, side: .left)
        tree = FolderTreeViewController(workspace: workspace, side: .left)
        let split = NSSplitViewController()
        split.addSplitViewItem(NSSplitViewItem(viewController: tree))
        split.addSplitViewItem(NSSplitViewItem(viewController: controller))
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 300),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = split
        workspace.onChange = { [controller, tree] in
            controller.render()
            tree.render()
        }
        window.makeKeyAndOrderFront(nil)
        for _ in 0 ..< 200 where workspace.state(of: .left).visibleEntries.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        workspace.onChange?()
        window.layoutIfNeeded()
    }

    isolated deinit {
        window.close()
    }

    @Test func theDefaultsLookLikeAppKitsSmallRows() throws {
        let small = NSTableView()
        small.style = .fullWidth
        small.rowSizeStyle = .small
        #expect(ListFonts.current(FontSettings()).rowHeight == small.rowHeight)
        #expect(controller.tableView.rowHeight == small.rowHeight && tree.outlineView.rowHeight == small.rowHeight)
        let name = try font("name")
        #expect(name.pointSize == NSFont.smallSystemFontSize)
        #expect(name.familyName == NSFont.systemFont(ofSize: 11).familyName)
        #expect(try font("permissions").isFixedPitch)
    }

    @Test func aNewFaceAndSizeShowInEveryColumnAndTheTree() throws {
        workspace.settings.font = FontSettings(face: "Helvetica", mono: "Menlo", size: 16)
        workspace.onChange?()
        #expect(try font("name").familyName == "Helvetica")
        #expect(try font("size").familyName == "Helvetica")
        for column in ["modified", "permissions"] {
            let mono = try font(column)
            #expect(mono.familyName == "Menlo" && mono.pointSize == 16, "\(column)")
        }
        let height = controller.tableView.rowHeight
        #expect(height > ListFonts.current(FontSettings()).rowHeight)
        #expect(controller.tableView.rect(ofRow: 0).height == height)
        #expect(tree.outlineView.rowHeight == height)
        let treeFonts = try (0 ..< tree.outlineView.numberOfRows).map { row in
            try #require((tree.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?
                .textField?.font)
        }
        #expect(!treeFonts.isEmpty && treeFonts.allSatisfy { $0.familyName == "Helvetica" && $0.pointSize == 16 })
        // The dates still fit their column in the new, wider font.
        let date = try #require(cell("modified").textField?.stringValue) as NSString
        let column = try #require(controller.tableView.tableColumns.first { $0.identifier.rawValue == "modified" })
        #expect(try column.width >= date.size(withAttributes: [.font: font("modified")]).width)
    }

    /// Seravek's own figures are proportional; it has tabular ones too. (A face without them, such
    /// as Georgia, keeps its own.)
    @Test func sizesUseTheFacesTabularFigures() throws {
        workspace.settings.font = FontSettings(face: "Seravek", size: 13)
        workspace.onChange?()
        let size = try font("size")
        let ones = ("111" as NSString).size(withAttributes: [.font: size]).width
        let zeros = ("000" as NSString).size(withAttributes: [.font: size]).width
        #expect(abs(ones - zeros) < 0.01)
    }

    @Test func aFastFilterMatchIsBoldInTheChosenFace() async throws {
        workspace.settings.font = FontSettings(face: "Helvetica", size: 12)
        workspace.perform(.setQuickFilter(.left, QuickFilter("notes", mode: .highlight)))
        try await waitUntil { self.workspace.state(of: .left).highlighted == ["notes.txt"] }
        workspace.onChange?()
        let bold = try font("name", of: "notes.txt")
        #expect(bold.familyName == "Helvetica" && bold.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(try !font("name", of: "docs").fontDescriptor.symbolicTraits.contains(.bold))
    }

    /// #63: Ctrl+wheel over the list or the tree zooms; without Ctrl the wheel scrolls.
    @Test func controlWheelZoomsTheListAndTheTree() throws {
        let before = workspace.settings.font.size
        try controller.tableView.scrollWheel(with: wheel(lines: 1, control: true))
        #expect(workspace.settings.font.size == before + 1)
        try tree.outlineView.scrollWheel(with: wheel(lines: -1, control: true))
        try tree.outlineView.scrollWheel(with: wheel(lines: -1, control: true))
        #expect(workspace.settings.font.size == before - 1)
        try controller.tableView.scrollWheel(with: wheel(lines: 1, control: false))
        #expect(workspace.settings.font.size == before - 1)
        #expect(controller.tableView.rowHeight == ListFonts.current(workspace.settings.font).rowHeight)
    }

    /// A mouse wheel's notch, as the window server sends it (not a trackpad's smooth scrolling).
    private func wheel(lines: Int32, control: Bool) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines,
                                         wheel2: 0, wheel3: 0))
        event.flags = control ? .maskControl : []
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        return try #require(NSEvent(cgEvent: event))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    private func cell(_ column: String, of name: String = "notes.txt") throws -> NSTableCellView {
        let table = controller.tableView
        let columnIndex = try #require(table.tableColumns.firstIndex { $0.identifier.rawValue == column })
        let row = try #require(controller.entries.firstIndex { $0.entry.name == name })
        table.layoutSubtreeIfNeeded()
        return try #require(table.view(atColumn: columnIndex, row: row, makeIfNecessary: true) as? NSTableCellView)
    }

    private func font(_ column: String, of name: String = "notes.txt") throws -> NSFont {
        try #require(cell(column, of: name).textField?.font)
    }
}

/// #63: quitting right after a zoom saves the size before the app goes (applicationShouldTerminate
/// replies once `finishSaving` is done; the test host itself must not quit, so the step is run here).
@MainActor
struct QuitSavesTheFontSizeTests {
    @Test func theSizeIsSavedBeforeTheReply() async throws {
        let folder = NSTemporaryDirectory() + "BlitterAppTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/settings.toml"
        try "[font]\nsize = 11\n".write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = Workspace(initialLocation: "/", home: "/home", lister: { _ in [] },
                                  directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory,
                                  settingsFile: path)
        workspace.fontSizeSaveDelay = .seconds(60)
        workspace.perform(.zoomFont(.larger))
        #expect(workspace.pendingFontSize == 12)
        var replied = false
        AppDelegate.finishSaving(workspace) { replied = true }
        for _ in 0 ..< 300 where !replied {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(replied)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "[font]\nsize = 12\n")
    }

    /// A save stuck on a stalled disk: the reply comes after the limit anyway, exactly once.
    @Test func aStalledSaveDoesNotHoldUpTheReply() async throws {
        let folder = NSTemporaryDirectory() + "BlitterAppTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/settings.toml"
        try "[font]\nsize = 11\n".write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = Workspace(initialLocation: "/", home: "/home", lister: { _ in [] },
                                  directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory,
                                  settingsFile: path)
        let stall = DispatchSemaphore(value: 0)
        workspace.settingsFileBeforeReplace = { _ = stall.wait(timeout: .now() + 5) }
        workspace.fontSizeSaveDelay = .zero
        workspace.perform(.zoomFont(.larger))
        var replies = 0
        let start = ContinuousClock.now
        AppDelegate.finishSaving(workspace, limit: .milliseconds(200)) { replies += 1 }
        for _ in 0 ..< 300 where replies == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(replies == 1)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(workspace.pendingFontSize == 12) // still stalled
        stall.signal()
        for _ in 0 ..< 300 where workspace.pendingFontSize != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(replies == 1) // the save finishing later does not reply again
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "[font]\nsize = 12\n")
    }
}
