import AppKit
@testable import Blitter
import BlitterCore
@testable import BlitterModel
import Testing

/// Git colors in the file list (#22), with and without a theme.
@MainActor
@Suite(.serialized)
final class GitColorTests {
    private let workspace: Workspace
    private let controller: FileListViewController
    private let window: NSWindow

    init() async throws {
        let listings = ["/fake": [folder("repo"), folder("plain"), file("a.txt")],
                        "/fake/repo": [folder("src"), folder("docs")]]
        workspace = Workspace(initialLocation: "/fake", home: "/home", lister: { listings[$0] ?? [] },
                              directoryCheck: { listings[$0] != nil }, volumes: { [] }, watcher: FakeWatcher.factory)
        workspace.gitAccess = GitAccess(repositoryRoot: { $0.hasPrefix("/fake/repo") ? "/fake/repo" : nil },
                                        isRepositoryRoot: { $0 == "/fake/repo" },
                                        status: { _, _ in
                                            GitRepoStatus(behind: 1, changed: ["src/main.swift"],
                                                          trackedFolders: ["", "src", "docs"])
                                        })
        controller = FileListViewController(workspace: workspace, side: .left)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 300),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        workspace.onChange = { [controller] in controller.render() }
        window.makeKeyAndOrderFront(nil)
        for _ in 0 ..< 300 where workspace.gitState(ofFolder: "/fake/repo") == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        controller.render()
        controller.view.layoutSubtreeIfNeeded()
    }

    isolated deinit {
        window.close()
    }

    @Test func aWorkingCopyRowTakesItsStateColor() throws {
        #expect(try color("repo") == .systemRed) // changes in it; no theme: the system color
        #expect(try color("plain") == .labelColor)
        #expect(try color("a.txt") == .labelColor)

        workspace.settings.theme.light = "solarized-dark"
        workspace.settings.theme.dark = "solarized-dark"
        workspace.onChange?()
        let themed = try #require(color("repo").usingColorSpace(.sRGB))
        #expect(Int((themed.redComponent * 255).rounded()) == 0xDC) // base08, red

        workspace.settings.gitColors = false
        workspace.onChange?()
        #expect(try color("repo") != themed)
    }

    /// Going into a working copy whose status is already known (and does not change): its
    /// folders are colored from the new listing, not the one before.
    @Test func enteringAKnownWorkingCopyColorsItsFolders() async throws {
        let version = workspace.gitVersion
        workspace.perform(.open(.left, name: "repo"))
        for _ in 0 ..< 300 where controller.entries.map(\.entry.name) != ["docs", "src"] {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100)) // the re-read finds nothing new
        #expect(workspace.gitVersion == version)
        controller.view.layoutSubtreeIfNeeded()
        #expect(try color("src") == .systemRed)
        #expect(try color("docs") == .systemGreen) // tracked and unchanged (#35)
    }

    private func color(_ name: String) throws -> NSColor {
        let row = try #require(controller.entries.firstIndex { $0.entry.name == name })
        let cell = controller.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
        return try #require(cell?.textField?.textColor)
    }
}
