import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

/// Find (#48): a search below a side's folder, its results shown as that side's listing, and
/// normal commands working on them.
@MainActor
@Suite(.serialized)
struct FindTests {
    /// left/ holds: x.swift, a/y.swift, a/b/z.SWIFT, a/b/match.txt, a/match-dir/, a/notes.swiftlint.yml,
    /// .hidden/h.swift, a/Tool.app/Contents/q.swift (a package), loop -> left (a link).
    private func tree() throws -> SidesOnDisk {
        let sides = try SidesOnDisk()
        for folder in ["left/a/b", "left/a/match-dir", "left/.hidden", "left/a/Tool.app/Contents"] {
            try FileManager.default.createDirectory(
                atPath: sides.root + "/" + folder,
                withIntermediateDirectories: true
            )
        }
        for file in ["left/x.swift", "left/a/y.swift", "left/a/b/z.SWIFT", "left/a/b/match.txt",
                     "left/a/notes.swiftlint.yml", "left/.hidden/h.swift", "left/a/Tool.app/Contents/q.swift"]
        {
            sides.file(file)
        }
        try FileManager.default.createSymbolicLink(atPath: sides.left + "/loop", withDestinationPath: sides.left)
        return sides
    }

    private func found(_ sides: SidesOnDisk) -> [String] {
        sides.names(.left).sorted()
    }

    @Test func aPatternFindsWholeNamesBelowTheFolder() async throws {
        let sides = try tree()
        try await sides.settle()
        sides.workspace.perform(.find(.left, pattern: "*.swift"))
        #expect(sides.workspace.state(of: .left).find?.isRunning == true)
        try await sides.settle()
        let state = sides.workspace.state(of: .left)
        // Case-insensitive; not the .swiftlint.yml; not inside the package, the hidden folder or the link.
        #expect(found(sides) == ["a/b/z.SWIFT", "a/y.swift", "x.swift"])
        #expect(state.find?.isRunning == false && state.status == .loaded)
        #expect(state.find?.foldersSearched == 4) // left, a, a/b, a/match-dir
        #expect(state.location == sides.left && state.entriesLocation == sides.left)
        #expect(state.find?.displayLocation == "search://" + sides.left + "?name=*.swift")

        sides.workspace.perform(.find(.left, pattern: "match")) // no wildcard: anywhere in the name
        try await sides.settle()
        #expect(found(sides) == ["a/b/match.txt", "a/match-dir"])
        #expect(sides.workspace.state(of: .left).backStack == [sides.left]) // one step back, not two
    }

    @Test func commandsWorkOnTheResults() async throws {
        let sides = try tree()
        try await sides.settle()
        sides.workspace.perform(.find(.left, pattern: "*.swift"))
        try await sides.settle()
        sides.workspace.perform(.select(.left, ["a/b/z.SWIFT"]))
        #expect(sides.workspace.selectedItems(on: .left).map(\.path) == [sides.left + "/a/b/z.SWIFT"])
        // Renaming or a new folder would name something in the searched folder itself: not here.
        #expect(!sides.workspace.canRun("rename", on: .left) && !sides.workspace.canRun("new-folder", on: .left))
        #expect(!sides.workspace.actions(for: .left).contains { $0.id == "rename" })
        #expect(sides.workspace.canRun("copy-path", on: .left))

        // A move to the other side: the results are read again, without it.
        sides.workspace.perform(.moveToOtherSide)
        try await sides.settle()
        #expect(sides.onDisk("right") == ["z.SWIFT"])
        #expect(found(sides) == ["a/y.swift", "x.swift"])
        #expect(sides.workspace.state(of: .left).find != nil)
    }

    @Test func openingAFolderOrGoingBackEndsTheSearch() async throws {
        let sides = try tree()
        try await sides.settle()
        sides.workspace.perform(.find(.left, pattern: "match"))
        try await sides.settle()
        sides.workspace.perform(.open(.left, name: "a/match-dir"))
        try await sides.settle()
        #expect(sides.workspace.state(of: .left).location == sides.left + "/a/match-dir")
        #expect(sides.workspace.state(of: .left).find == nil)

        sides.workspace.perform(.goBack(.left)) // to the folder that was searched, as a listing
        try await sides.settle()
        #expect(sides.workspace.state(of: .left).location == sides.left)
        #expect(sides.workspace.state(of: .left).find == nil)
        #expect(found(sides) == ["a", "loop", "x.swift"])

        sides.workspace.perform(.find(.left, pattern: "match"))
        try await sides.settle()
        sides.workspace.perform(.find(.left, pattern: "  ")) // empty: back to the folder
        try await sides.settle()
        #expect(sides.workspace.state(of: .left).find == nil && found(sides) == ["a", "loop", "x.swift"])
    }

    @Test func hiddenItemsFollowTheSetting() async throws {
        let sides = try tree()
        try await sides.settle()
        sides.workspace.perform(.find(.left, pattern: "*.swift"))
        try await sides.settle()
        sides.workspace.perform(.toggleHiddenFiles) // the hidden folder is searched now
        try await sides.settle()
        #expect(found(sides) == [".hidden/h.swift", "a/b/z.SWIFT", "a/y.swift", "x.swift"])
        #expect(sides.workspace.state(of: .left).visibleEntries.first { $0.entry.name == ".hidden/h.swift" }?
            .entry.isHidden == true) // inside a hidden folder: hidden itself
        sides.workspace.perform(.toggleHiddenFiles)
        try await sides.settle()
        #expect(found(sides) == ["a/b/z.SWIFT", "a/y.swift", "x.swift"])
    }

    @Test func anUnreadableFolderIsCountedAndSkipped() async throws {
        let sides = try tree()
        let locked = sides.left + "/a/b"
        chmod(locked, 0)
        defer { chmod(locked, 0o755) }
        try await sides.settle()
        sides.workspace.perform(.find(.left, pattern: "*.swift"))
        try await sides.settle()
        #expect(found(sides) == ["a/y.swift", "x.swift"])
        #expect(sides.workspace.state(of: .left).find?.unreadableFolders == 1)
    }

    /// Stop keeps what was found; a big tree, stopped right away.
    @Test func stopKeepsWhatWasFound() async throws {
        let sides = try SidesOnDisk()
        for index in 0 ..< 3000 {
            try FileManager.default.createDirectory(
                atPath: sides.left + "/d\(index)",
                withIntermediateDirectories: false
            )
        }
        try await sides.settle()
        sides.workspace.perform(.find(.left, pattern: "d1*"))
        sides.workspace.perform(.stopFind(.left))
        try await sides.settle()
        let find = try #require(sides.workspace.state(of: .left).find)
        #expect(!find.isRunning && sides.workspace.state(of: .left).status == .loaded)
        #expect(find.foldersSearched < 3001) // stopped before all of them were read
        #expect(found(sides).allSatisfy { $0.hasPrefix("d1") })
    }

    @Test func theWholeNameMatcherKeepsTheFastFilterAsItWas() {
        let whole = QuickFilter.Matcher("*.swift", wholeName: true)
        #expect(whole.matches("main.Swift") && !whole.matches("notes.swiftlint.yml"))
        #expect(QuickFilter.Matcher("swift", wholeName: true).matches("notes.swiftlint.yml"))
        #expect(QuickFilter.Matcher("*.swift").matches("notes.swiftlint.yml")) // the fast filter: anywhere
    }

    /// The walk hands its results over as it goes, in batches with the counts so far, and always
    /// ends with one; a new search shows nothing old meanwhile, a search run again keeps its rows.
    @Test func resultsComeInBatchesAndARunAgainKeepsTheOldRows() async throws {
        let sides = try tree()
        var batches: [FindBatch] = []
        FileFind.walk(root: sides.left, matcher: QuickFilter.Matcher("*.swift", wholeName: true), includeHidden: false,
                      cancelled: CancellationFlag(), interval: 0) { batches.append($0) }
        #expect(batches.count == 5) // one per folder read, and the last
        #expect(batches.map(\.foldersSearched) == [1, 2, 3, 4, 4])
        #expect(batches.flatMap(\.entries).map(\.name).sorted() == ["a/b/z.SWIFT", "a/y.swift", "x.swift"])
        #expect(batches[0].entries.map(\.name) == ["x.swift"]) // breadth first: the top comes first

        try await sides.settle()
        sides.workspace.perform(.find(.left, pattern: "*.swift"))
        #expect(sides.names(.left).isEmpty && sides.workspace.state(of: .left).status == .loading) // a new one
        try await sides.settle()
        sides.workspace.perform(.refresh(.left)) // run again
        #expect(found(sides) == ["a/b/z.SWIFT", "a/y.swift", "x.swift"]) // still shown meanwhile
        #expect(sides.workspace.state(of: .left).find?.isRunning == true)
        try await sides.settle()
        #expect(found(sides) == ["a/b/z.SWIFT", "a/y.swift", "x.swift"])
    }

    /// A change the watcher reports does not walk the tree again; Refresh does.
    @Test func watchedChangesLeaveTheResultsAlone() async throws {
        let sides = try tree()
        try await sides.settle()
        sides.workspace.perform(.find(.left, pattern: "*.swift"))
        try await sides.settle()
        sides.file("left/new.swift")
        sides.workspace.foldersChanged([FolderChange(path: sides.left, includesSubfolders: true)])
        #expect(sides.workspace.findWork[.left] == nil && sides.workspace.state(of: .left).find?.isRunning == false)
        try await sides.settle()
        #expect(found(sides) == ["a/b/z.SWIFT", "a/y.swift", "x.swift"])
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        #expect(found(sides) == ["a/b/z.SWIFT", "a/y.swift", "new.swift", "x.swift"])
    }
}
