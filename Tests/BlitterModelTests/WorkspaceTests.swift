import BlitterCore
@testable import BlitterModel
import Foundation
import Testing
import UniformTypeIdentifiers

func entry(_ name: String, _ kind: DirectoryEntry.Kind = .file, size: Int64 = 0, modified: TimeInterval = 0,
           hidden: Bool = false) -> DirectoryEntry
{
    DirectoryEntry(name: name, kind: kind, size: size, modificationDate: Date(timeIntervalSince1970: modified),
                   isHidden: hidden || name.hasPrefix("."), isDataless: false, error: 0)
}

/// Returns a fixed listing per call; `results` are used in order, the last one repeats.
final class FakeLister: Sendable {
    private let results: Mutex<[Result<[DirectoryEntry], POSIXError>]>
    let delays: [Double]

    init(_ results: [Result<[DirectoryEntry], POSIXError>], delays: [Double] = []) {
        self.results = Mutex(results)
        self.delays = delays
    }

    convenience init(_ entries: [DirectoryEntry]) {
        self.init([.success(entries)])
    }

    private let calls = Mutex(0)

    func list(_: String) async throws -> [DirectoryEntry] {
        let (call, result) = results.withLock { results in
            let call = calls.withLock { calls in
                calls += 1
                return calls
            }
            return (call, results.count > 1 ? results.removeFirst() : results[0])
        }
        let delay = call <= delays.count ? delays[call - 1] : 0
        if delay > 0 {
            // Deliberately ignores cancellation, like a listing stuck in a system call.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { continuation.resume() }
            }
        }
        return try result.get()
    }
}

import Synchronization

@MainActor
struct WorkspaceTests {
    private func makeWorkspace(_ lister: FakeLister) async -> Workspace {
        let workspace = Workspace(initialLocation: "/folder", lister: lister.list)
        await settle(workspace)
        return workspace
    }

    private func settle(_ workspace: Workspace) async {
        for side in Side.allCases {
            await workspace.pendingWork[side]?.value
        }
    }

    private func names(_ workspace: Workspace, _ side: Side = .left) -> [String] {
        workspace.state(of: side).visibleEntries.map(\.entry.name)
    }

    @Test func oppositeSide() {
        #expect(Side.left.opposite == .right)
        #expect(Side.right.opposite == .left)
    }

    @Test func bothSidesLoadTheInitialLocationWithLeftActive() async {
        let workspace = await makeWorkspace(FakeLister([entry("a")]))
        for side in Side.allCases {
            #expect(workspace.state(of: side).location == "/folder")
            #expect(workspace.state(of: side).status == .loaded)
            #expect(names(workspace, side) == ["a"])
        }
        #expect(workspace.activeSide == .left)
    }

    @Test func switchAndActivateChangeTheActiveSideAndNotify() async {
        let workspace = await makeWorkspace(FakeLister([]))
        var changes = 0
        workspace.onChange = { changes += 1 }

        workspace.perform(.switchActiveSide)
        #expect(workspace.activeSide == .right)
        workspace.perform(.activate(.right))
        #expect(changes == 1) // already active: no change, no notification
        workspace.perform(.activate(.left))
        #expect(workspace.activeSide == .left)
        #expect(changes == 2)
    }

    @Test func foldersFirstThenNaturalNameOrder() async {
        let workspace = await makeWorkspace(FakeLister([
            entry("file10"), entry("File2"), entry("zeta", .directory), entry("alpha", .directory), entry("file1"),
        ]))
        #expect(names(workspace) == ["alpha", "zeta", "file1", "File2", "file10"])
    }

    @Test func sortBySizeDescendingKeepsFoldersFirst() async {
        let workspace = await makeWorkspace(FakeLister([
            entry("a", size: 1), entry("b", size: 100), entry("dir", .directory), entry("c", size: 50),
        ]))
        workspace.perform(.sort(.left, ListSort(column: .size, ascending: false)))
        await settle(workspace)
        #expect(names(workspace) == ["dir", "b", "c", "a"])
        // The other side keeps its own sort order (by name).
        #expect(names(workspace, .right) == ["dir", "a", "b", "c"])
    }

    @Test func sortByModifiedAndEqualKeysFallBackToName() async {
        let workspace = await makeWorkspace(FakeLister([
            entry("b", modified: 10), entry("a", modified: 10), entry("c", modified: 5),
        ]))
        workspace.perform(.sort(.left, ListSort(column: .modified, ascending: true)))
        await settle(workspace)
        #expect(names(workspace) == ["c", "a", "b"])
    }

    @Test func sortByKindUsesTheKindDescription() async {
        let workspace = await makeWorkspace(FakeLister([entry("x.pdf"), entry("y.txt"), entry("z.pdf")]))
        workspace.perform(.sort(.left, ListSort(column: .kind, ascending: true)))
        await settle(workspace)

        let pdf = UTType.pdf.localizedDescription ?? ""
        let text = UTType(filenameExtension: "txt")?.localizedDescription ?? ""
        let pdfFirst = pdf.localizedStandardCompare(text) == .orderedAscending
        let expected = pdfFirst ? ["x.pdf", "z.pdf", "y.txt"] : ["y.txt", "x.pdf", "z.pdf"]
        #expect(names(workspace) == expected)
        let kinds = Dictionary(uniqueKeysWithValues: workspace.state(of: .left).visibleEntries
            .map { ($0.entry.name, $0.kindDescription) })
        #expect(kinds == ["x.pdf": pdf, "z.pdf": pdf, "y.txt": text])
    }

    @Test func foldersOnlyGetARegisteredFolderType() async {
        let workspace = await makeWorkspace(FakeLister([
            entry("archive.pdf", .directory), entry("Tool.app", .directory), entry("plain", .directory),
            entry("notes.zzqq"), entry("stuff.zzqq", .directory), entry("report.pdf"),
        ]))
        let listed = Dictionary(uniqueKeysWithValues: workspace.state(of: .left).visibleEntries
            .map { ($0.entry.name, $0) })
        let app = UTType.applicationBundle.localizedDescription ?? ""
        #expect(listed["archive.pdf"]?.kindDescription == "Folder")
        #expect(listed["archive.pdf"]?.contentType == .folder)
        #expect(listed["plain"]?.kindDescription == "Folder")
        #expect(listed["Tool.app"]?.kindDescription == app)
        #expect(listed["Tool.app"]?.contentType.conforms(to: .package) == true)
        // An unknown extension shared by a file and a folder: each keeps its own fallback.
        #expect(listed["notes.zzqq"]?.kindDescription == "Document")
        #expect(listed["stuff.zzqq"]?.kindDescription == "Folder")
        #expect(listed["report.pdf"]?.contentType == .pdf)
    }

    @Test func hiddenFilesAreFilteredUntilToggled() async {
        let workspace = await makeWorkspace(FakeLister([entry(".secret"), entry("flagged", hidden: true),
                                                        entry("visible")]))
        #expect(names(workspace) == ["visible"])

        workspace.perform(.toggleHiddenFiles)
        await settle(workspace)
        #expect(workspace.showsHiddenFiles)
        #expect(Set(names(workspace)) == [".secret", "flagged", "visible"])
        #expect(Set(names(workspace, .right)) == [".secret", "flagged", "visible"])
    }

    @Test func failedListingReportsTheErrorAndClearsTheSide() async {
        let workspace = await makeWorkspace(FakeLister([.failure(POSIXError(.EACCES))]))
        let state = workspace.state(of: .left)
        #expect(state.status == .failed("/folder: Permission denied"))
        #expect(state.visibleEntries.isEmpty)
    }

    @Test func selectionKeepsOnlyNamesThatStillExistAfterRefresh() async {
        let lister = FakeLister([.success([entry("a"), entry("b")]), .success([entry("a"), entry("b")]),
                                 .success([entry("a")])])
        let workspace = await makeWorkspace(lister)
        workspace.perform(.select(.left, ["a", "b"]))
        #expect(workspace.state(of: .left).selection == ["a", "b"])

        workspace.perform(.refresh(.left))
        await settle(workspace)
        #expect(workspace.state(of: .left).selection == ["a"])
    }

    @Test func entriesVersionChangesOnNewListingsButNotOnSelection() async {
        let workspace = await makeWorkspace(FakeLister([entry("a")]))
        let version = workspace.state(of: .left).entriesVersion
        workspace.perform(.select(.left, ["a"]))
        #expect(workspace.state(of: .left).entriesVersion == version)
        workspace.perform(.refresh(.left))
        await settle(workspace)
        #expect(workspace.state(of: .left).entriesVersion > version)
    }

    /// A slow listing that finishes after a newer one must not overwrite the newer result.
    @Test func staleListingIsDiscarded() async throws {
        // Calls 1 and 2 are the initial loads of both sides; call 3 is a slow refresh of the left
        // side, call 4 a fast one that supersedes it.
        let lister = FakeLister([.success([entry("initial")]), .success([entry("initial")]),
                                 .success([entry("stale")]), .success([entry("fresh")])],
                                delays: [0, 0, 0.3, 0])
        let workspace = await makeWorkspace(lister)

        workspace.perform(.refresh(.left))
        try await Task.sleep(for: .milliseconds(50)) // the slow call is now in flight
        workspace.perform(.refresh(.left))
        await settle(workspace)
        #expect(names(workspace) == ["fresh"])

        try await Task.sleep(for: .milliseconds(400)) // the slow call has returned by now
        #expect(names(workspace) == ["fresh"])
        #expect(workspace.state(of: .left).status == .loaded)
    }
}

/// Timing probe for sorting a large listing. Skipped in normal runs; `just bench` runs it.
struct ListingBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLITTER_BENCHMARK"] != nil))
    func sortOneHundredThousandEntries() {
        let extensions = ["txt", "pdf", "swift", "jpg", "", "md"]
        let entries = (0 ..< 100_000).map { (index: Int) -> DirectoryEntry in
            let name = "file \(index * 7919 % 100_000).\(extensions[index % extensions.count])"
            let kind: DirectoryEntry.Kind = index % 20 == 0 ? .directory : .file
            return entry(name, kind, size: Int64(index * 31 % 5000), modified: Double(index))
        }
        let clock = ContinuousClock()
        for column in SortColumn.allCases {
            var result: [ListedEntry] = []
            let duration = clock.measure {
                result = Listing.visibleEntries(entries, showHidden: false, sort: ListSort(column: column))
            }
            #expect(result.count == entries.count)
            print("BENCHMARK sort 100000 entries by \(column): \(duration)")
        }
    }
}
