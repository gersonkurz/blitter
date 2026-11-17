import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

/// #108: Select Differences — on each side, what the other lacks or has older.
@MainActor
@Suite(.serialized)
struct SelectDifferencesTests {
    private let day = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func file(_ name: String, _ size: Int64 = 1, _ seconds: TimeInterval = 0) -> DirectoryEntry {
        DirectoryEntry(name: name, kind: .file, size: size, modificationDate: day.addingTimeInterval(seconds),
                       isHidden: false, isDataless: false, error: 0)
    }

    private func folder(_ name: String, _ seconds: TimeInterval = 0) -> DirectoryEntry {
        DirectoryEntry(name: name, kind: .directory, size: 0, modificationDate: day.addingTimeInterval(seconds),
                       isHidden: false, isDataless: false, error: 0)
    }

    @Test func theRules() {
        let left = [
            file("only-left.txt"), folder("only-left-folder"),
            file("newer-left.txt", 1, 10), file("newer-right.txt", 1, 0),
            file("same.txt", 5, 0), file("rounded.txt", 5, 1.5), // within 2 s, same size: equal
            file("resized.txt", 5, 0), // same date, other size: both sides
            folder("both-folder", 100), folder("App.app"), // folders (packages too) on both: never
            file("Case.TXT", 1, 10), // the same name in another case
            file("kind"), // a file here, a folder there: not compared
        ]
        let right = [
            file("only-right.txt"), folder("only-right-folder"),
            file("newer-left.txt", 1, 0), file("newer-right.txt", 1, 10),
            file("same.txt", 5, 0), file("rounded.txt", 5, 0),
            file("resized.txt", 6, 1),
            folder("both-folder", 0), folder("App.app", 50),
            file("case.txt", 1, 0),
            folder("kind"),
        ]
        let (onLeft, onRight) = Workspace.differences(left, right)
        #expect(onLeft == ["only-left.txt", "only-left-folder", "newer-left.txt", "resized.txt", "Case.TXT"])
        #expect(onRight == ["only-right.txt", "only-right-folder", "newer-right.txt", "resized.txt"])
    }

    @Test func emptySidesHaveNothingInCommon() {
        #expect(Workspace.differences([], []) == ([], []))
        #expect(Workspace.differences([file("a")], []) == (["a"], []))
    }

    /// Through the action, on real folders: both sides are selected; what is not shown (a hidden
    /// file) is not; F5 then copies the active side's.
    @Test func theActionSelectsBothSidesAsShown() async throws {
        let sides = try SidesOnDisk()
        sides.file("left/a.txt", "a")
        sides.file("left/.hidden", "h")
        sides.file("right/b.txt", "b")
        sides.file("left/same.txt", "s")
        sides.file("right/same.txt", "s")
        let past = Date().addingTimeInterval(-3600) // the same moment on both sides
        for path in [sides.left + "/same.txt", sides.right + "/same.txt"] {
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: path)
        }
        sides.workspace.perform(.refresh(.left))
        sides.workspace.perform(.refresh(.right))
        try await sides.settle()
        #expect(sides.workspace.canRun("select-differences", on: .left))
        sides.workspace.perform(.runAction("select-differences", .left))
        try await sides.settle() // compared off the main thread
        #expect(sides.workspace.state(of: .left).selection == ["a.txt"])
        #expect(sides.workspace.state(of: .right).selection == ["b.txt"])

        sides.workspace.perform(.copyToOtherSide) // F5: the active side's
        try await sides.settle()
        #expect(sides.onDisk("right").contains("a.txt") && !sides.onDisk("right").contains(".hidden"))
    }

    /// A search's results are no folder to compare: not offered there.
    @Test func notOfferedForSearchResults() async throws {
        let sides = try SidesOnDisk()
        sides.workspace.perform(.find(.left, pattern: "*"))
        try await sides.settle()
        #expect(!sides.workspace.canRun("select-differences", on: .left))
    }

    // MARK: #108 review

    private func twoSides() async throws -> SidesOnDisk {
        let sides = try SidesOnDisk()
        sides.file("left/a.txt", "a")
        sides.file("right/b.txt", "b")
        sides.workspace.perform(.refresh(.left))
        sides.workspace.perform(.refresh(.right))
        try await sides.settle()
        return sides
    }

    /// A listing that changes while the two are compared (a reload landed) gets nothing applied:
    /// the result is about the old listing.
    @Test func aResultForAChangedListingIsNotApplied() async throws {
        let sides = try await twoSides()
        sides.workspace.perform(.selectDifferences)
        sides.workspace.sides[.left]?.entriesVersion += 1 // as a reload that changed the listing
        try await sides.settle()
        #expect(sides.workspace.state(of: .left).selection.isEmpty)
        #expect(sides.workspace.state(of: .right).selection.isEmpty)
    }

    /// Going elsewhere on either side cancels the comparison.
    @Test func navigatingCancelsIt() async throws {
        let sides = try await twoSides()
        sides.workspace.perform(.selectDifferences)
        let work = try #require(sides.workspace.differenceWork)
        sides.workspace.perform(.navigate(.right, path: sides.root))
        #expect(work.isCancelled && sides.workspace.differenceWork == nil)
        try await sides.settle()
        #expect(sides.workspace.state(of: .left).selection.isEmpty)
    }

    /// Search results on the other side: not offered, and the command does nothing.
    @Test func searchResultsOnTheOtherSideAreNoFolderEither() async throws {
        let sides = try await twoSides()
        sides.workspace.perform(.find(.right, pattern: "*"))
        try await sides.settle()
        #expect(!sides.workspace.canRun("select-differences", on: .left))
        #expect(!sides.workspace.actions(for: .left).contains { $0.id == "select-differences" })
        sides.workspace.perform(.selectDifferences)
        try await sides.settle()
        #expect(sides.workspace.state(of: .left).selection.isEmpty)
    }

    /// Through automation: when it answers done, both sides are selected.
    @Test func automationIsAnsweredOnceBothSidesAreSelected() async throws {
        let sides = try await twoSides()
        let result = try await sides.workspace.runAutomated(["action": "select-differences", "side": "left"],
                                                            client: "test")
        #expect(result["done"] == true)
        #expect(sides.workspace.state(of: .left).selection == ["a.txt"])
        #expect(sides.workspace.state(of: .right).selection == ["b.txt"])
    }

    @Test func aCancelledComparisonStops() {
        let many = (0 ..< 5000).map { file("f\($0)") }
        var asked = 0
        let found = Workspace.differences(many, [], cancelled: {
            asked += 1
            return asked > 2
        })
        #expect(found == nil && asked == 3)
        // Only on the right: its passes ask too (#108 review).
        asked = 0
        #expect(Workspace.differences([], many, cancelled: {
            asked += 1
            return asked > 2
        }) == nil && asked == 3)
        // Not cancelled: every pass asks, and finishes.
        asked = 0
        let whole = Workspace.differences(many, many, cancelled: {
            asked += 1
            return false
        })
        #expect(whole?.left == [] && whole?.right == [] && asked == 15) // 5 checks in each of 3 passes
    }
}
