import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

/// Configurable columns (#25): per side, following the settings file until changed there.
@MainActor
struct ColumnsTests {
    /// By name: open, script, secret; by size or permissions: secret, script, open.
    private func item(_ name: String, _ mode: UInt16, size: Int64) -> DirectoryEntry {
        DirectoryEntry(name: name, kind: .file, size: size, modificationDate: Date(timeIntervalSince1970: 0),
                       isHidden: false, isDataless: false, error: 0, permissions: mode)
    }

    private func makeWorkspace(restoring saved: WorkspaceState? = nil, settingsFile: String? = nil) async
        -> Workspace
    {
        let folders = FakeFolders(["/home": [
            item("open", 0o777, size: 3), item("secret", 0o600, size: 1), item("script", 0o755, size: 2),
        ]])
        let workspace = Workspace(initialLocation: "/home", home: "/home", lister: folders.list,
                                  directoryCheck: folders.isDirectory, volumes: { [] },
                                  watcher: FakeWatcher.factory, restoring: saved, settingsFile: settingsFile)
        await workspace.settle()
        return workspace
    }

    private func names(_ workspace: Workspace) -> [String] {
        workspace.state(of: .left).visibleEntries.map(\.entry.name)
    }

    /// Waits until the settings file has been read (again) and the side re-listed.
    private func waitForSettings(_ workspace: Workspace, _ ready: () -> Bool) async throws {
        for _ in 0 ..< 300 where !ready() {
            try await Task.sleep(for: .milliseconds(5))
        }
        await workspace.settle()
    }

    @Test func eachSideShowsAndHidesItsOwnColumns() async {
        let workspace = await makeWorkspace()
        #expect(workspace.columns(of: .left) == [.name, .size, .modified])
        var changes = 0
        workspace.onChange = { changes += 1 }

        workspace.perform(.showColumn(.left, .permissions, true))
        workspace.perform(.showColumn(.left, .size, false))
        #expect(workspace.columns(of: .left) == [.name, .modified, .permissions])
        #expect(workspace.columns(of: .right) == [.name, .size, .modified]) // the other side keeps its own
        #expect(changes == 2)

        workspace.perform(.showColumn(.left, .name, false)) // Name always shows
        workspace.perform(.showColumn(.left, .permissions, true)) // already shown
        #expect(workspace.columns(of: .left).contains(.name))
        #expect(changes == 2)
    }

    @Test func aSideFollowsTheSettingsUntilChangedAndAfterADefaultColumnsReset() async {
        let workspace = await makeWorkspace()
        workspace.settings.columns = [.name, .git]
        #expect(workspace.columns(of: .left) == [.name, .git] && workspace.columns(of: .right) == [.name, .git])

        workspace.perform(.showColumn(.left, .kind, true))
        workspace.settings.columns = [.name, .size]
        #expect(workspace.columns(of: .left) == [.name, .git, .kind]) // changed here: its own
        #expect(workspace.columns(of: .right) == [.name, .size])

        workspace.perform(.resetColumns(.left))
        #expect(workspace.columns(of: .left) == [.name, .size])
        #expect(workspace.state(of: .left).columns == nil)
    }

    @Test func hidingTheSortedColumnSortsByName() async {
        let workspace = await makeWorkspace()
        workspace.perform(.showColumn(.left, .permissions, true))
        workspace.perform(.sort(.left, ListSort(column: .permissions, ascending: true)))
        await workspace.settle()
        #expect(workspace.state(of: .left).visibleEntries.map(\.entry.name) == ["secret", "script", "open"])

        workspace.perform(.showColumn(.left, .permissions, false))
        await workspace.settle()
        #expect(workspace.state(of: .left).sort == ListSort())
        #expect(workspace.state(of: .left).visibleEntries.map(\.entry.name) == ["open", "script", "secret"])

        // The same when Default Columns hides it.
        workspace.perform(.showColumn(.left, .kind, true))
        workspace.perform(.sort(.left, ListSort(column: .kind, ascending: false)))
        workspace.perform(.resetColumns(.left))
        #expect(workspace.state(of: .left).sort == ListSort())
    }

    /// #25 review: a side that follows the settings loses the sorted column when the settings
    /// file drops it; the list is sorted by name again, not by something invisible.
    @Test func aSettingsChangeThatHidesTheSortedColumnSortsByName() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        try "[files]\ncolumns = [\"size\"]\n".write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = await makeWorkspace(settingsFile: path)
        try await waitForSettings(workspace) { workspace.settings.columns == [.name, .size] }
        workspace.perform(.sort(.left, ListSort(column: .size, ascending: true)))
        await workspace.settle()
        #expect(names(workspace) == ["secret", "script", "open"])

        try "[files]\ncolumns = [\"modified\"]\n".write(toFile: path, atomically: true, encoding: .utf8)
        workspace.loadSettings() // what the watcher does when the file changes
        try await waitForSettings(workspace) { workspace.settings.columns == [.name, .modified] }
        #expect(workspace.state(of: .left).sort == ListSort())
        #expect(names(workspace) == ["open", "script", "secret"])
    }

    /// #25 review: a sort by a column the settings file shows survives a restart, although the
    /// side never changed its columns (nil: follows the settings, which are read after restoring).
    @Test func aSavedSortByASettingsColumnSurvivesARestart() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        try "[files]\ncolumns = [\"size\", \"kind\"]\n".write(toFile: path, atomically: true, encoding: .utf8)
        let byKind = ListSort(column: .kind, ascending: false)
        let saved = WorkspaceState(left: .init(location: "/home", sort: byKind),
                                   right: .init(location: "/home", sort: byKind), showsHiddenFiles: false)
        let workspace = await makeWorkspace(restoring: saved, settingsFile: path)
        try await waitForSettings(workspace) { workspace.settings.columns.contains(.kind) }
        #expect(workspace.state(of: .left).sort == byKind)

        // Without Kind in the settings it goes back to the default sort (the #13 rule), once
        // the settings are known.
        try "[files]\ncolumns = [\"size\"]\n".write(toFile: path, atomically: true, encoding: .utf8)
        let other = await makeWorkspace(restoring: saved, settingsFile: path)
        try await waitForSettings(other) { other.settings.columns == [.name, .size] }
        #expect(other.state(of: .left).sort == ListSort())
        // Without a settings file the defaults are final at once (PersistenceTests covers it too).
        #expect(await makeWorkspace(restoring: saved).state(of: .left).sort == ListSort())
    }

    @Test func changedColumnsAreSavedAndComeBack() async throws {
        let workspace = await makeWorkspace()
        #expect(workspace.savedState.left.columns == nil) // never changed: follows the settings
        workspace.perform(.showColumn(.left, .git, true))
        workspace.perform(.showColumn(.left, .kind, true))
        workspace.perform(.sort(.left, ListSort(column: .kind, ascending: false)))
        let saved = workspace.savedState
        #expect(saved.left.columns == ["name", "size", "modified", "kind", "git"])
        #expect(saved.right.columns == nil)

        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(saved))
        let restored = await makeWorkspace(restoring: decoded)
        #expect(restored.columns(of: .left) == [.name, .size, .modified, .kind, .git])
        #expect(restored.state(of: .right).columns == nil)
        // Kind is shown here, so a sort by it stays (#13 dropped it only while Kind was hidden).
        #expect(restored.state(of: .left).sort == ListSort(column: .kind, ascending: false))
    }

    @Test func savedStatesFromBeforeAndAfterThisVersionStillLoad() async throws {
        // Before #25: no columns at all.
        let old = #"{"left":{"location":"/home","sort":{"column":"name","ascending":true}},"#
            + #""right":{"location":"/home","sort":{"column":"name","ascending":true}},"showsHiddenFiles":false}"#
        let before = try JSONDecoder().decode(WorkspaceState.self, from: Data(old.utf8))
        #expect(before.left.columns == nil)
        // A column a later version has and this one does not is skipped; Name is always there.
        var later = before
        later.left.columns = ["size", "owner"]
        let restored = await makeWorkspace(restoring: later)
        #expect(restored.columns(of: .left) == [.name, .size])
    }

    @Test func theSettingsFileNamesTheColumns() {
        let (settings, problems) = Settings.parse("[files]\ncolumns = [\"size\", \"permissions\", \"git\"]\n")
        #expect(problems.isEmpty)
        #expect(settings.columns == [.name, .size, .permissions, .git]) // Name need not be named

        for bad in ["columns = [\"size\", \"owner\"]", "columns = \"size\"", "columns = [1]"] {
            let (kept, problems) = Settings.parse("[files]\n\(bad)\n")
            #expect(kept.columns == ListColumn.defaults, "\(bad)")
            #expect(problems.count == 1 && problems[0].contains("\"permissions\""), "\(bad)")
        }
        #expect(Settings.parse(Settings.defaultFile).settings.columns == ListColumn.defaults)
    }
}
