import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

/// The listing's name index (#47): selected entries are looked up, not searched for.
@MainActor
struct ListingIndexTests {
    @Test func selectedEntriesComeInListOrderByLookup() async {
        let folders = FakeFolders(["/f": [entry("b.txt"), entry("Sub", .directory), entry("a.txt"), entry("c.txt")]])
        let workspace = Workspace(initialLocation: "/f", home: "/f", lister: folders.list,
                                  directoryCheck: folders.isDirectory, volumes: { [] }, watcher: FakeWatcher.factory)
        await workspace.settle()
        let state = { workspace.state(of: .left) }
        #expect(state().visibleIndex == ["Sub": 0, "a.txt": 1, "b.txt": 2, "c.txt": 3])

        workspace.perform(.select(.left, ["c.txt", "a.txt", "Sub", "gone.txt"]))
        #expect(state().selectedEntries.map(\.entry.name) == [
            "Sub",
            "a.txt",
            "c.txt",
        ]) // list order; gone is not listed
        #expect(workspace.selectedItems(on: .left).map(\.isDirectory) == [true, false, false])
        #expect(state().listed("b.txt")?.entry.name == "b.txt" && state().listed("nope") == nil)

        // Sorted the other way: the index follows the new order.
        workspace.perform(.sort(.left, ListSort(column: .name, ascending: false)))
        await workspace.settle()
        #expect(state().selectedEntries.map(\.entry.name) == ["Sub", "c.txt", "a.txt"]) // folders stay first
    }

    /// Few selected are looked up, many are found in one pass: both give the same answers
    /// (#47 review: the pass is faster for a large selection, and stops early at a folder).
    @Test func fewOrManySelectedGiveTheSameAnswers() async {
        let names = (0 ..< 40).map { String(format: "f%02d.txt", $0) }
        let folders = FakeFolders(["/f": [entry("Dir", .directory)] + names.map { entry($0) }])
        let workspace = Workspace(initialLocation: "/f", home: "/f", lister: folders.list,
                                  directoryCheck: folders.isDirectory, volumes: { [] }, watcher: FakeWatcher.factory)
        await workspace.settle()
        let state = { workspace.state(of: .left) }

        workspace.perform(.select(.left, ["f30.txt", "f02.txt", "gone"]))
        #expect(state().selectionIsSparse)
        #expect(state().selectedEntries.map(\.entry.name) == ["f02.txt", "f30.txt"])
        #expect(workspace.canRun("open-in-text-editor", on: .left)) // files only
        workspace.perform(.select(.left, ["f30.txt", "Dir"]))
        #expect(state().selectionIsSparse && !workspace.canRun("open-in-text-editor", on: .left))

        workspace.perform(.select(.left, Set(names.dropFirst(5))))
        #expect(!state().selectionIsSparse)
        #expect(state().selectedEntries.map(\.entry.name) == Array(names.dropFirst(5)))
        #expect(workspace.canRun("open-in-text-editor", on: .left))
        workspace.perform(.select(.left, Set(names + ["Dir"])))
        #expect(!state().selectionIsSparse && !workspace.canRun("open-in-text-editor", on: .left))
    }

    @Test func anIndexOutOfStepNeverGivesAWrongEntry() async {
        let folders = FakeFolders(["/f": [entry("a.txt"), entry("b.txt")]])
        let workspace = Workspace(initialLocation: "/f", home: "/f", lister: folders.list,
                                  directoryCheck: folders.isDirectory, volumes: { [] }, watcher: FakeWatcher.factory)
        await workspace.settle()
        workspace.perform(.select(.left, ["a.txt", "b.txt"]))
        // The rows changed under the index (as a test or a future bug might do).
        workspace.sides[.left]?.visibleEntries.reverse()
        #expect(workspace.state(of: .left).listed("a.txt") == nil) // row 0 is b.txt now: not taken for a.txt
        workspace.sides[.left]?.visibleEntries = []
        #expect(workspace.state(of: .left).selectedEntries.isEmpty)
        #expect(workspace.state(of: .left).listed("b.txt") == nil)
    }
}
