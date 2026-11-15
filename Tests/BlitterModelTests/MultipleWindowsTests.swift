@testable import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

/// #96: a second window's workspace shares the app's state with the first: the jobs and their
/// undo, the notices, the favorites, the colors being tried, the settings. Its sides are its own.
@MainActor
@Suite(.serialized)
struct MultipleWindowsTests {
    private func settle(_ sides: SidesOnDisk, _ other: Workspace) async throws {
        try await sides.settle()
        await other.settle()
    }

    @Test func aJobFromOneWindowShowsInBothAndIsUndoneFromTheOther() async throws {
        let sides = try SidesOnDisk()
        let first = sides.workspace
        let second = Workspace(sharingWith: first, location: sides.right)
        var seen = (first: 0, second: 0)
        first.onChange = { seen.first += 1 }
        second.onChange = { seen.second += 1 }
        #expect(first.app === second.app && first.app.workspaces.count == 2)
        sides.file("left/a.txt")
        first.perform(.refresh(.left))
        try await settle(sides, second)
        #expect(second.state(of: .left).location == sides.right) // its own sides
        #expect(second.state(of: .left).visibleEntries.isEmpty)

        first.perform(.select(.left, ["a.txt"]))
        seen = (0, 0)
        first.perform(.copyToOtherSide)
        #expect(second.jobs.count == 1 && seen.second > 0) // its strip shows the job too
        try await settle(sides, second)
        // Its watcher is a fake: the finished job made it read the folder it changed.
        #expect(second.state(of: .left).visibleEntries.map(\.entry.name) == ["a.txt"])
        #expect(second.jobs.isEmpty) // it worked: gone from every strip
        #expect(first.undoJournal.count == 1) // recorded once, though two windows saw it end

        let entry = try #require(second.lastUndo)
        #expect(entry.title == "Copy" && second.canUndo)
        second.perform(.undo(entry: entry.id))
        try await settle(sides, second)
        #expect(sides.onDisk("right").isEmpty && first.lastUndo == nil)
        #expect(first.state(of: .right).visibleEntries.isEmpty)
    }

    @Test func noticesFavoritesAndTriedColorsAreEveryWindows() async throws {
        let sides = try SidesOnDisk()
        let first = sides.workspace
        let second = Workspace(sharingWith: first, location: sides.left)
        try await settle(sides, second)
        var seen = 0
        second.onChange = { seen += 1 }

        first.perform(.showNotice("Something happened."))
        #expect(second.notices.map(\.text) == ["Something happened."] && seen == 1)

        first.perform(.addFavorite(sides.right))
        #expect(second.favorites.last == sides.right)
        #expect(second.treeRoots.contains { $0.path == sides.right })

        var trial = ThemeSettings()
        trial.dark = "nord"
        second.perform(.tryTheme(trial))
        #expect(first.shownTheme.dark == "nord")
    }

    @Test func aClosedWindowIsForgotten() async throws {
        let sides = try SidesOnDisk()
        var second: Workspace? = Workspace(sharingWith: sides.workspace, location: sides.left)
        try await settle(sides, #require(second))
        #expect(sides.workspace.app.workspaces.count == 2)
        second = nil
        #expect(sides.workspace.app.workspaces.count == 1)
    }

    /// A window opened after the settings were read takes them as they are: a saved sort on a
    /// column the settings hide goes back to Name at once, as the first window's did when read.
    @Test func aLaterWindowTakesTheSettingsAsRead() async throws {
        let folder = NSTemporaryDirectory() + "BlitterWindows-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let file = folder + "/settings.toml"
        try "[files]\ncolumns = [\"name\"]\n".write(toFile: file, atomically: true, encoding: .utf8)
        let first = Workspace(initialLocation: "/", home: "/home", lister: { _ in [] },
                              directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory,
                              settingsFile: file)
        await first.settle()
        #expect(first.settings.columns == [.name])
        let saved = WorkspaceState(left: .init(location: "/", sort: ListSort(column: .size, ascending: true)),
                                   right: .init(location: "/", sort: ListSort()), showsHiddenFiles: false)
        let second = Workspace(sharingWith: first, location: "/", restoring: saved)
        #expect(second.state(of: .left).sort == ListSort()) // Size is not shown
        #expect(first.app.settingsReads == 1) // read once, for both
    }

    /// #96 review: the settings file is every window's. A favorite added in a window closed before
    /// its save ran is still written, and the save's state cleared, when another window waits.
    @Test func aSaveStartedInAClosedWindowStillHappens() async throws {
        let folder = NSTemporaryDirectory() + "BlitterWindows-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let file = folder + "/settings.toml"
        try "[files]\n".write(toFile: file, atomically: true, encoding: .utf8)
        let first = Workspace(initialLocation: "/", home: "/home", lister: { _ in [] },
                              directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory,
                              settingsFile: file)
        await first.settle()
        var second: Workspace? = Workspace(sharingWith: first, location: "/")
        try #require(second).perform(.addFavorite("/Volumes/Data"))
        #expect(first.app.pendingFavorites != nil)
        second = nil // closed before the save ran: the save holds it until it is done

        await first.finishSavingFavorites()
        let written = try String(contentsOfFile: file, encoding: .utf8)
        #expect(Settings.parse(written).settings.favorites?.last == "/Volumes/Data")
        #expect(first.app.pendingFavorites == nil && first.app.favoritesSave == nil)
        for _ in 0 ..< 100 where first.app.workspaces.count > 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(first.app.workspaces.count == 1) // then it goes
    }
}
