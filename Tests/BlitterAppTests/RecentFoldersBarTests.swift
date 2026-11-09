import AppKit
@testable import Blitter
@testable import BlitterModel
import Testing

/// #74: the recent folders strip: a button per folder (pinned ones marked), a click goes there,
/// the right-click menu pins, unpins or forgets.
@MainActor
struct RecentFoldersBarTests {
    @Test func buttonsGoThereAndTheirMenuChangesTheStrip() throws {
        let bar = RecentFoldersBar(side: .right)
        var commands: [String] = []
        bar.onCommand = { commands.append(String(describing: $0)) }
        bar.render([], pinned: [])
        #expect(bar.isHidden && bar.buttons.isEmpty) // nothing to show: no room taken

        bar.render(["/Users/me/Downloads", "/", "/Users/me/Projects/blitter"], pinned: ["/Users/me/Downloads"])
        #expect(!bar.isHidden)
        #expect(bar.buttons.map(\.title) == ["Downloads", "/", "blitter"])
        #expect(bar.buttons.map(\.toolTip) == ["/Users/me/Downloads", "/", "/Users/me/Projects/blitter"])
        #expect(bar.buttons[0].image != nil && bar.buttons[1].image == nil) // pinned: marked

        bar.buttons[2].performClick(nil)
        #expect(commands == ["activate(BlitterModel.Side.right)",
                             "navigate(BlitterModel.Side.right, path: \"/Users/me/Projects/blitter\")"])

        let pinnedMenu = try #require(bar.buttons[0].menu)
        #expect(pinnedMenu.items.map(\.title) == ["Unpin", "Remove from Recent Folders"])
        let menu = try #require(bar.buttons[2].menu)
        #expect(menu.items.map(\.title) == ["Pin to Recent Folders", "Remove from Recent Folders"])
        commands = []
        menu.performActionForItem(at: 0)
        let pinned = "recentFolder(BlitterModel.Side.right, \"/Users/me/Projects/blitter\", "
            + "BlitterModel.RecentFolderChange.pin)"
        #expect(commands == [pinned])
    }
}

/// The strip laid out in a window: narrow, the last (least frecent) buttons go first; wide, they
/// come back; a long first name never pushes the window wider (#74 review).
@MainActor
struct RecentFoldersBarLayoutTests {
    @Test func whatDoesNotFitGoesLeastFrecentFirst() throws {
        let bar = RecentFoldersBar(side: .left)
        bar.translatesAutoresizingMaskIntoConstraints = false
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1800, height: 60),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false // ARC owns it; AppKit releasing it too would crash
        defer { window.close() }
        let content = try #require(window.contentView)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.topAnchor.constraint(equalTo: content.topAnchor),
        ])
        let folders = ["/a/A very long first folder name that takes room"] + (1 ... 12).map { "/folder\($0)" }
        bar.render(folders, pinned: [])
        func shown() -> [String] {
            content.layoutSubtreeIfNeeded()
            return bar.buttons.filter { $0.superview != nil && !$0.isHidden }.map(\.title)
        }
        let wide = shown()
        #expect(wide.count == folders.count) // all fit

        window.setContentSize(NSSize(width: 360, height: 60))
        let narrow = shown()
        #expect(narrow.count < wide.count && narrow.first == "A very long first folder name that takes room")
        #expect(narrow == Array(wide.prefix(narrow.count))) // the last ones went
        #expect(abs(window.contentLayoutRect.width - 360) < 1) // the strip did not widen the window

        window.setContentSize(NSSize(width: 1800, height: 60))
        #expect(shown() == wide) // back again
    }
}
