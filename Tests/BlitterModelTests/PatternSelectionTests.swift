import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

/// Select by pattern: names matching join or leave the selection.
@MainActor
struct PatternSelectionTests {
    private func makeWorkspace(slow: Set<String> = []) async -> Workspace {
        let folders = FakeFolders([
            "/home": [entry("Archive", .directory), entry("readme.md"), entry("Résumé.pdf"), entry("notes.txt"),
                      entry("todo.txt"), entry(".secret.txt")],
            "/home/Archive": [entry("old.txt")],
        ], slow: slow)
        let workspace = Workspace(initialLocation: "/home", home: "/home", lister: folders.list,
                                  directoryCheck: folders.isDirectory, volumes: { [] }, watcher: FakeWatcher.factory)
        await workspace.settle()
        return workspace
    }

    private func select(_ workspace: Workspace, _ pattern: String, _ mode: PatternSelectionMode = .select) async {
        workspace.perform(.selectByPattern(.left, pattern, mode))
        await workspace.settle()
    }

    private func selection(_ workspace: Workspace) -> Set<String> {
        workspace.state(of: .left).selection
    }

    @Test func matchesJoinAndLeaveTheSelection() async {
        let workspace = await makeWorkspace()
        await select(workspace, "*.txt")
        #expect(selection(workspace) == ["notes.txt", "todo.txt"]) // a hidden item is not listed
        await select(workspace, " *.md ; resume* ") // several; case and accents do not matter
        #expect(selection(workspace) == ["notes.txt", "todo.txt", "readme.md", "Résumé.pdf"])
        await select(workspace, "NOTES*", .deselect)
        #expect(selection(workspace) == ["todo.txt", "readme.md", "Résumé.pdf"])
        await select(workspace, "arch") // without a wildcard: anywhere in the name, folders too
        #expect(selection(workspace).contains("Archive"))
        await select(workspace, " ; ", .deselect) // no pattern: nothing changes
        #expect(selection(workspace).count == 4)
        await select(workspace, "*", .deselect)
        #expect(selection(workspace).isEmpty)
    }

    @Test func aMatchFinishingAfterTheSideLeftIsNotApplied() async {
        let workspace = await makeWorkspace(slow: ["/home/Archive"])
        workspace.perform(.selectByPattern(.left, "*", .select))
        workspace.perform(.navigate(.left, path: "/home/Archive"))
        // The match is done while the new folder is still being read: nothing is selected in
        // the old rows, which are still shown.
        for _ in 0 ..< 400 where workspace.patternWork[.left] != nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(workspace.state(of: .left).entriesLocation == "/home")
        #expect(selection(workspace).isEmpty)
        await workspace.settle()
        #expect(workspace.state(of: .left).entriesLocation == "/home/Archive")
        #expect(selection(workspace).isEmpty)
    }

    @Test func goingAwayAndBackBeforeTheMatchIsDoneDropsIt() async {
        let workspace = await makeWorkspace()
        workspace.perform(.selectByPattern(.left, "*", .select))
        workspace.perform(.navigate(.left, path: "/home/Archive"))
        workspace.perform(.goBack(.left)) // the same folder again, its old listing still shown
        await workspace.settle()
        #expect(workspace.state(of: .left).entriesLocation == "/home")
        #expect(selection(workspace) == ["Archive"]) // the folder we came from, as always; no match

        // A new search drops it too, even though the side's folder stays the same.
        workspace.perform(.selectByPattern(.left, "*", .select))
        workspace.perform(.find(.left, pattern: "*.txt"))
        await workspace.settle()
        #expect(selection(workspace).isEmpty)
    }

    @Test func searchResultsMatchByTheirOwnName() async throws {
        let temporary = try TemporaryFolder()
        try FileManager.default.createDirectory(atPath: temporary.path + "/sub", withIntermediateDirectories: false)
        for name in ["a.txt", "sub/b.txt", "sub/c.md"] {
            FileManager.default.createFile(atPath: temporary.path + "/" + name, contents: Data())
        }
        let workspace = Workspace(initialLocation: temporary.path, home: temporary.path,
                                  directoryCheck: { _ in true }, volumes: { [] }, watcher: FakeWatcher.factory)
        await workspace.settle()
        workspace.perform(.find(.left, pattern: "*"))
        await workspace.settle()
        await select(workspace, "b*")
        #expect(selection(workspace) == ["sub/b.txt"])
    }
}
