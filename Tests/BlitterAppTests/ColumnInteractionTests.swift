import AppKit
@testable import Blitter
import BlitterCore
@testable import BlitterModel
import Testing

/// Configurable columns in the file list (#25): the header's menu, and the Permissions and Git
/// columns.
@MainActor
@Suite(.serialized)
final class ColumnInteractionTests {
    private let workspace: Workspace
    private let controller: FileListViewController
    private let window: NSWindow

    init() async throws {
        var script = file("run.sh")
        script.permissions = 0o4750
        let listings = ["/fake": [folder("repo"), script]]
        workspace = Workspace(initialLocation: "/fake", home: "/home", lister: { listings[$0] ?? [] },
                              directoryCheck: { listings[$0] != nil }, volumes: { [] }, watcher: FakeWatcher.factory)
        workspace.gitAccess = GitAccess(repositoryRoot: { $0.hasPrefix("/fake/repo") ? "/fake/repo" : nil },
                                        isRepositoryRoot: { $0 == "/fake/repo" },
                                        status: { _, _ in GitRepoStatus(ahead: 3, behind: 2, trackedFolders: [""]) })
        controller = FileListViewController(workspace: workspace, side: .left)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 300),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        workspace.onChange = { [controller] in controller.render() }
        window.makeKeyAndOrderFront(nil)
        for _ in 0 ..< 300 where workspace.gitStatus(of: "/fake/repo", isFolder: true) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        controller.render()
    }

    isolated deinit {
        window.close()
    }

    private var visibleTitles: [String] {
        controller.tableView.tableColumns.filter { !$0.isHidden }.map(\.title)
    }

    @Test func theHeadersMenuShowsAndHidesColumnsAndGoesBackToTheDefaults() throws {
        let menu = try #require(controller.tableView.headerView?.menu)
        controller.menuNeedsUpdate(menu)
        #expect(menu.items.map(\.title) == ["Size", "Date Modified", "Kind", "Permissions", "Git", "",
                                            "Default Columns"])
        #expect(menu.items.prefix(5).map(\.state) == [.on, .on, .off, .off, .off])

        menu.performActionForItem(at: 3) // Permissions
        controller.menuNeedsUpdate(menu)
        menu.performActionForItem(at: 0) // Size
        #expect(workspace.columns(of: .left) == [.name, .modified, .permissions])
        #expect(visibleTitles == ["Name", "Date Modified", "Permissions"])
        controller.menuNeedsUpdate(menu)
        #expect(menu.items.prefix(5).map(\.state) == [.off, .on, .off, .on, .off])

        menu.performActionForItem(at: 6) // Default Columns
        #expect(visibleTitles == ["Name", "Size", "Date Modified"])
    }

    @Test func permissionsAndGitShowInTheirColumns() throws {
        workspace.perform(.showColumn(.left, .permissions, true))
        workspace.perform(.showColumn(.left, .git, true))
        controller.view.layoutSubtreeIfNeeded()
        #expect(try text("run.sh", .permissions) == "rwsr-x---")
        #expect(try text("repo", .git) == "↑3 ↓2")
        #expect(try text("run.sh", .git) == "") // not in a working copy
        let font = try #require(cell("run.sh", .permissions).textField?.font)
        #expect(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
        // The Git column does not sort: its states arrive after the listing.
        let gitColumn = try #require(controller.tableView.tableColumn(withIdentifier: FileListViewController.gitColumn))
        #expect(gitColumn.sortDescriptorPrototype == nil)
    }

    @Test func permissionsReadAsLsShowsThem() {
        let cases: [(UInt16, String)] = [
            (0o755, "rwxr-xr-x"), (0o644, "rw-r--r--"), (0o000, "---------"), (0o4755, "rwsr-xr-x"),
            (0o4644, "rwSr--r--"), (0o2755, "rwxr-sr-x"), (0o2745, "rwxr-Sr-x"), (0o1777, "rwxrwxrwt"),
            (0o1666, "rw-rw-rwT"),
        ]
        for (mode, text) in cases {
            #expect(FileListViewController.permissions(mode) == text, "\(String(mode, radix: 8))")
        }
        let words = [GitItemStatus.unchanged, .modified, .untracked, .ignored, .aheadOrBehind(ahead: 1, behind: 0),
                     .aheadOrBehind(ahead: 0, behind: 4)].map(FileListViewController.text(of:))
        #expect(words == ["Unchanged", "Modified", "Untracked", "Ignored", "↑1", "↓4"])
    }

    private func cell(_ name: String, _ column: ListColumn) throws -> NSTableCellView {
        let row = try #require(controller.entries.firstIndex { $0.entry.name == name })
        let index = controller.tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))
        return try #require(controller.tableView.view(atColumn: index, row: row, makeIfNecessary: true)
            as? NSTableCellView)
    }

    private func text(_ name: String, _ column: ListColumn) throws -> String {
        try cell(name, column).textField?.stringValue ?? "?"
    }
}
