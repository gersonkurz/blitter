import AppKit
@testable import Blitter
import BlitterCore
@testable import BlitterModel
import Testing

/// README.md's picture (#100), made like the manual's (`just screenshots`): a taller window with
/// fuller folders than the manual's scenes — the project's sources on the left, revealed in the
/// tree, holiday pictures on the right — in light and dark; GitHub shows the one that fits.
extension ManualScreenshots {
    @Test func readmeWindow() async throws {
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            // Each side starts at its own folder, so each tree reveals its own.
            let start = WorkspaceState(left: .init(location: ReadmeDemo.sources, sort: ListSort()),
                                       right: .init(location: ReadmeDemo.pictures, sort: ListSort()),
                                       showsHiddenFiles: false)
            let workspace = Workspace(initialLocation: ReadmeDemo.sources, home: ReadmeDemo.home,
                                      lister: { ReadmeDemo.listings[$0] ?? [] }, directoryCheck: { _ in true },
                                      volumes: { [] }, watcher: FakeWatcher.factory, restoring: start)
            let controller = MainWindowController(workspace: workspace)
            let window = try #require(controller.window)
            window.title = "Blitter" // no version: a release does not change every picture (#117)
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: 1440, height: 640))
            controller.showWindow(nil)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            defer { controller.close() }
            // Trees wide enough for the deepest names.
            for side in Self.sideControllers(in: window.contentViewController) {
                side.splitView.setPosition(250, ofDividerAt: 0)
            }
            try await Self.waitUntil {
                Side.allCases.allSatisfy { workspace.state(of: $0).visibleEntries.count > 8 }
            }
            workspace.perform(.activate(.left))
            workspace.perform(.select(.left, ["MainWindows.swift", "MainWindowController.swift"]))
            try await Self.capture(window, as: "readme-\(name).png")
        }
    }

    private static func sideControllers(in controller: NSViewController?) -> [SideViewController] {
        guard let controller else {
            return []
        }
        return [controller as? SideViewController].compactMap(\.self)
            + controller.children.flatMap { sideControllers(in: $0) }
    }
}

/// Demo folders of the README's picture: fixed names, sizes and dates, nothing of the user's.
private enum ReadmeDemo {
    static let home = "/Users/demo"
    static let projects = home + "/Projects"
    static let project = projects + "/blitter"
    static let sources = project + "/Sources/BlitterApp"
    static let pictures = home + "/Pictures/Iceland 2026"

    static let listings: [String: [DirectoryEntry]] = [
        home: ["Desktop", "Documents", "Downloads", "Pictures", "Projects"].map { folder($0, day: 12) },
        home + "/Pictures": [folder("Iceland 2026", day: 15), folder("Screenshots", day: 10)],
        projects: [folder("blitter", day: 15), folder("dotfiles", day: 3), folder("website", day: 9)],
        project: ["Sources", "Tests", "docs", "tools"].map { folder($0, day: 15) }
            + [file("README.md", 4812, day: 15), file("justfile", 7406, day: 15), file("project.yml", 3210, day: 15)],
        project + "/Sources": ["BlitterApp", "BlitterCLI", "BlitterCore", "BlitterGit", "BlitterModel"]
            .map { folder($0, day: 15) },
        sources: [folder("Git", day: 15)] + [
            ("AppDelegate.swift", 11840), ("AppDelegate+MenuBar.swift", 5122), ("AppDelegate+Windows.swift", 1404),
            ("CommandLineTool.swift", 8017), ("FileIcons.swift", 6230), ("FileListViewController.swift", 15520),
            ("FolderTreeViewController.swift", 9925), ("JobsViewController.swift", 8740),
            ("MainWindowController.swift", 7968), ("MainWindows.swift", 6302), ("Palette.swift", 7410),
            ("SettingsColors.swift", 4410), ("SettingsWindow.swift", 11265), ("SideViewController.swift", 2051),
            ("StateStore.swift", 2178), ("WindowToolbar.swift", 6904),
        ].enumerated().map { index, item in file(item.0, Int64(item.1), day: 15 - index % 4) },
        pictures: (1 ... 14).map { number in
            file(String(format: "IMG_%04d.jpg", 4100 + number * 7), Int64(3_100_000 + number * 211_337),
                 day: 1 + number)
        } + [file("Route.gpx", 88420, day: 14), file("Notes.md", 2310, day: 15)],
    ]

    static func date(_ day: Int, _ hour: Int) -> Date {
        DateComponents(calendar: .current, year: 2026, month: 11, day: day, hour: hour, minute: 12).date
            ?? .distantPast
    }

    static func folder(_ name: String, day: Int) -> DirectoryEntry {
        DirectoryEntry(name: name, kind: .directory, size: 0, modificationDate: date(day, 9), isHidden: false,
                       isDataless: false, error: 0)
    }

    static func file(_ name: String, _ size: Int64, day: Int) -> DirectoryEntry {
        DirectoryEntry(name: name, kind: .file, size: size, modificationDate: date(day, 14), isHidden: false,
                       isDataless: false, error: 0)
    }
}
