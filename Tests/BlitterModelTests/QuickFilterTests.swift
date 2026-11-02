import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

/// The fast filter (#39): highlight mode selects matches, filter mode lists only them.
@MainActor
struct QuickFilterTests {
    private func makeWorkspace() async -> Workspace {
        let folders = FakeFolders([
            "/home": [entry("Archive", .directory), entry("readme.md"), entry("Résumé.pdf"), entry("notes.txt"),
                      entry("todo.txt"), entry(".secret.txt")],
            "/home/Archive": [entry("old.txt")],
        ])
        let workspace = Workspace(initialLocation: "/home", home: "/home", lister: folders.list,
                                  directoryCheck: folders.isDirectory, volumes: { [] }, watcher: FakeWatcher.factory)
        await workspace.settle()
        return workspace
    }

    private func names(_ workspace: Workspace) -> [String] {
        workspace.state(of: .left).visibleEntries.map(\.entry.name)
    }

    @Test func matchingIgnoresCaseAndAccentsAndKnowsWildcards() {
        func matches(_ text: String, _ name: String) -> Bool {
            QuickFilter(text, mode: .filter).matches(name)
        }
        #expect(matches("", "anything"))
        #expect(matches("ME", "readme.md") && matches("resume", "Résumé.pdf") && matches("é", "Résumé.pdf"))
        #expect(!matches("txt", "readme.md"))
        #expect(matches("*.txt", "notes.txt") && matches("n*s", "notes.txt") && matches("t?do", "todo.txt"))
        #expect(!matches("t?o", "todo.txt")) // "?" is exactly one character
        #expect(!matches("x*y", "notes.txt") && !matches("no?es.md", "notes.txt"))
        // Many stars against a long name that does not match: no exponential backtracking.
        let start = Date()
        #expect(!matches(String(repeating: "a*", count: 30) + "b", String(repeating: "a", count: 2000)))
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func highlightSelectsTheFirstMatchAndStepsThroughThemAll() async {
        let workspace = await makeWorkspace()
        #expect(names(workspace) == ["Archive", "notes.txt", "readme.md", "Résumé.pdf", "todo.txt"])
        workspace.perform(.setQuickFilter(.left, QuickFilter("t", mode: .highlight)))
        await workspace.settle() // matched in the background
        #expect(workspace.state(of: .left).highlighted == ["notes.txt", "todo.txt"])
        #expect(workspace.state(of: .left).selection == ["notes.txt"]) // Archive has no t
        #expect(names(workspace).count == 5) // highlighting lists everything
        workspace.perform(.selectQuickFilterMatch(.left, forward: true))
        #expect(workspace.state(of: .left).selection == ["todo.txt"])
        workspace.perform(.selectQuickFilterMatch(.left, forward: true)) // wraps around
        #expect(workspace.state(of: .left).selection == ["notes.txt"])
        workspace.perform(.selectQuickFilterMatch(.left, forward: false))
        #expect(workspace.state(of: .left).selection == ["todo.txt"])

        workspace.perform(.setQuickFilter(.left, QuickFilter("tx", mode: .highlight)))
        await workspace.settle()
        #expect(workspace.state(of: .left).selection == ["notes.txt"])
        workspace.perform(.setQuickFilter(.left, QuickFilter("txz", mode: .highlight))) // no match
        await workspace.settle()
        #expect(workspace.state(of: .left).selection == ["notes.txt"]) // kept
        #expect(workspace.state(of: .left).highlighted.isEmpty)
        #expect(!workspace.apply(.selectQuickFilterMatch(.left, forward: true)))
        workspace.perform(.setQuickFilter(.left, QuickFilter("", mode: .highlight))) // nothing typed: off
        #expect(workspace.state(of: .left).quickFilter == nil)
    }

    /// #39 review: while a search for the new listing runs, the highlights are still those of
    /// the old one; an arrow key then must not trap on an empty listing.
    @Test func steppingThroughMatchesOfAnEmptiedListingDoesNothing() async {
        let workspace = await makeWorkspace()
        workspace.perform(.setQuickFilter(.left, QuickFilter("t", mode: .highlight)))
        await workspace.settle()
        #expect(!workspace.state(of: .left).highlighted.isEmpty)
        workspace.sides[.left]?.visibleEntries = [] // the listing replaced, the search not done yet
        #expect(!workspace.apply(.selectQuickFilterMatch(.left, forward: true)))
        #expect(!workspace.apply(.selectQuickFilterMatch(.left, forward: false)))
    }

    /// #39 review: going elsewhere while a search runs: its result must not come back.
    @Test func aSearchStillRunningWhenTheSideGoesElsewhereIsDropped() async throws {
        let folders = FakeFolders(["/home": [entry("Archive", .directory), entry("notes.txt")],
                                   "/home/Archive": [entry("old.txt")]], slow: ["/home/Archive"], delay: 0.3)
        let workspace = Workspace(initialLocation: "/home", home: "/home", lister: folders.list,
                                  directoryCheck: folders.isDirectory, volumes: { [] }, watcher: FakeWatcher.factory)
        await workspace.settle()
        workspace.perform(.setQuickFilter(.left, QuickFilter("t", mode: .highlight))) // search starts
        workspace.perform(.navigate(.left, path: "/home/Archive")) // slow: the old rows stay a while
        try await Task.sleep(for: .milliseconds(100)) // the search would be long done
        #expect(workspace.state(of: .left).quickFilter == nil)
        #expect(workspace.state(of: .left).highlighted.isEmpty)
        #expect(workspace.state(of: .left).selection.isEmpty)
        await workspace.settle()
        #expect(names(workspace) == ["old.txt"] && workspace.state(of: .left).selection.isEmpty)
    }

    /// #39 review: typed before the listing is there, the first match is selected once it
    /// arrives; a later refresh leaves the user's own choice alone.
    @Test func typingBeforeTheListingArrivesSelectsTheFirstMatchOnceItDoes() async {
        let folders = FakeFolders(["/home": [entry("notes.txt"), entry("readme.md"), entry("todo.txt")]],
                                  slow: ["/home"], delay: 0.2)
        let workspace = Workspace(initialLocation: "/home", home: "/home", lister: folders.list,
                                  directoryCheck: folders.isDirectory, volumes: { [] }, watcher: FakeWatcher.factory)
        workspace.perform(.setQuickFilter(.left, QuickFilter("t", mode: .highlight))) // nothing listed yet
        await workspace.settle()
        #expect(workspace.state(of: .left).highlighted == ["notes.txt", "todo.txt"])
        #expect(workspace.state(of: .left).selection == ["notes.txt"])

        workspace.perform(.select(.left, ["readme.md"])) // the user's choice
        workspace.perform(.refresh(.left))
        await workspace.settle()
        #expect(workspace.state(of: .left).selection == ["readme.md"])
    }

    /// The highlights follow the listing: a folder read again may have new matches.
    @Test func aNewListingIsHighlightedAgain() async {
        let lister = FakeLister([.success([entry("a.txt"), entry("b.md")]),
                                 .success([entry("a.txt"), entry("b.md"), entry("c.txt")])])
        let workspace = Workspace(initialLocation: "/folder", home: "/folder", lister: lister.list,
                                  directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory)
        await workspace.settle()
        workspace.perform(.setQuickFilter(.left, QuickFilter("txt", mode: .highlight)))
        await workspace.settle()
        #expect(workspace.state(of: .left).highlighted == ["a.txt"])
        workspace.perform(.refresh(.left))
        await workspace.settle()
        #expect(workspace.state(of: .left).highlighted == ["a.txt", "c.txt"])
        #expect(workspace.state(of: .left).selection == ["a.txt"]) // a new listing does not move it
    }

    @Test func filterModeListsOnlyMatchesAndEndsWithTheFolder() async {
        let workspace = await makeWorkspace()
        workspace.perform(.select(.left, ["readme.md", "todo.txt"]))
        workspace.perform(.setQuickFilter(.left, QuickFilter("", mode: .filter)))
        await workspace.settle()
        #expect(names(workspace).count == 5) // nothing typed yet: everything
        workspace.perform(.setQuickFilter(.left, QuickFilter("*.txt", mode: .filter)))
        await workspace.settle()
        #expect(names(workspace) == ["notes.txt", "todo.txt"]) // .secret.txt stays hidden
        #expect(workspace.state(of: .left).selection == ["todo.txt"]) // what is not listed is not selected

        workspace.perform(.refresh(.left)) // read again: still filtered
        await workspace.settle()
        #expect(names(workspace) == ["notes.txt", "todo.txt"])

        workspace.perform(.open(.left, name: "notes.txt")) // a file: the side stays, so does the filter
        workspace.perform(.navigate(.left, path: "/home/Archive"))
        await workspace.settle()
        #expect(workspace.state(of: .left).quickFilter == nil)
        #expect(names(workspace) == ["old.txt"])

        workspace.perform(.navigate(.left, path: "/home"))
        workspace.perform(.setQuickFilter(.left, QuickFilter("me", mode: .filter)))
        await workspace.settle()
        #expect(names(workspace) == ["readme.md", "Résumé.pdf"])
        workspace.perform(.setQuickFilter(.left, nil))
        await workspace.settle()
        #expect(names(workspace).count == 5)
    }
}
