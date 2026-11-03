import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

/// Folder sizes on demand (#52), on real folders.
@MainActor
@Suite(.serialized)
struct FolderSizesTests {
    private func makeSides() throws -> SidesOnDisk {
        let sides = try SidesOnDisk()
        for folder in ["big/inner", "small", "empty"] {
            try FileManager.default.createDirectory(
                atPath: sides.left + "/" + folder,
                withIntermediateDirectories: true
            )
        }
        sides.file("left/big/inner/data", String(repeating: "x", count: 3000))
        sides.file("left/small/data", String(repeating: "x", count: 20))
        sides.file("left/file.txt", String(repeating: "x", count: 4))
        return sides
    }

    private func sizes(_ sides: SidesOnDisk) -> [String: FolderSize] {
        sides.workspace.state(of: .left).folderSizes
    }

    @Test func allFoldersOrTheSelectedOnesAreMeasured() async throws {
        let sides = try makeSides()
        try await sides.settle()
        let workspace = sides.workspace
        workspace.perform(.select(.left, ["file.txt"]))
        #expect(!workspace.canRun("folder-sizes", on: .left)) // no folder selected
        workspace.perform(.select(.left, ["small", "file.txt"]))
        #expect(workspace.canRun("folder-sizes", on: .left))
        workspace.perform(.runAction("folder-sizes", .left))
        #expect(sizes(sides) == ["small": .measuring])
        try await sides.settle()
        #expect(sizes(sides) == ["small": .measured(20)])
        #expect(workspace.state(of: .left).selectedTotals.bytes == 24)

        workspace.perform(.select(.left, []))
        workspace.perform(.runAction("folder-sizes", .left))
        try await sides.settle()
        #expect(sizes(sides) == ["big": .measured(3000), "small": .measured(20), "empty": .measured(0)])
        #expect(workspace.state(of: .left).shownTotals.bytes == 3024)
        #expect(workspace.state(of: .left).totals.bytes == 4) // the listing's own count stays files only

        // A reload keeps them; a folder that is gone loses its size.
        try FileManager.default.removeItem(atPath: sides.left + "/empty")
        workspace.reload(showing: [sides.left])
        try await sides.settle()
        #expect(sizes(sides) == ["big": .measured(3000), "small": .measured(20)])

        // Going anywhere forgets them, even the same folder again.
        workspace.perform(.navigate(.left, path: sides.left))
        #expect(sizes(sides).isEmpty)
    }

    @Test func folderSizesOutOfViewStayButAreNotInTheTotal() async throws {
        let sides = try makeSides()
        try FileManager.default.createDirectory(atPath: sides.left + "/.cache", withIntermediateDirectories: false)
        sides.file("left/.cache/data", String(repeating: "x", count: 7))
        try await sides.settle()
        let workspace = sides.workspace
        workspace.perform(.toggleHiddenFiles)
        try await sides.settle()
        workspace.perform(.measureFolderSizes(.left))
        try await sides.settle()
        #expect(sizes(sides).count == 4 && workspace.state(of: .left).shownTotals.bytes == 3031)

        // The fast filter leaves folders out for now: their sizes stay, the total is what is listed.
        workspace.perform(.setQuickFilter(.left, QuickFilter("small", mode: .filter)))
        try await sides.settle()
        #expect(sides.names(.left) == ["small"])
        #expect(sizes(sides).count == 4 && workspace.state(of: .left).shownTotals.bytes == 20)
        workspace.perform(.setQuickFilter(.left, nil))
        try await sides.settle()
        #expect(sizes(sides).count == 4 && workspace.state(of: .left).shownTotals.bytes == 3031)

        // So does hiding hidden items again.
        workspace.perform(.toggleHiddenFiles)
        try await sides.settle()
        #expect(sizes(sides)[".cache"] == .measured(7) && workspace.state(of: .left).shownTotals.bytes == 3024)
    }

    @Test func aResultForAFolderThatWentMeanwhileIsDropped() async throws {
        let sides = try makeSides()
        try await sides.settle()
        let workspace = sides.workspace
        let gate = DispatchSemaphore(value: 0)
        workspace.measureFolder = { path, cancelled in
            if path.hasSuffix("/small") {
                gate.wait() // still measuring when the folder is deleted and the side reloads
            }
            return FolderSizes.measure(path, cancelled: cancelled)
        }
        workspace.perform(.measureFolderSizes(.left))
        try FileManager.default.removeItem(atPath: sides.left + "/small")
        workspace.reload(showing: [sides.left])
        for _ in 0 ..< 400 where sizes(sides)["small"] != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(sizes(sides)["small"] == nil)
        gate.signal()
        try await sides.settle()
        #expect(sizes(sides) == ["big": .measured(3000), "empty": .measured(0)])
        #expect(workspace.state(of: .left).shownTotals.bytes == 3004)
    }

    @Test func sortingBySizeUsesThem() async throws {
        let sides = try makeSides()
        try await sides.settle()
        let workspace = sides.workspace
        workspace.perform(.sort(.left, ListSort(column: .size, ascending: false)))
        try await sides.settle()
        #expect(sides.names(.left) == ["small", "empty", "big", "file.txt"]) // no size known: by name, descending
        workspace.perform(.measureFolderSizes(.left))
        try await sides.settle()
        #expect(sides.names(.left) == ["small", "empty", "big", "file.txt"]) // nothing moves under the cursor (#57)
        #expect(sizes(sides)["big"] == .measured(3000))
        workspace.perform(.sort(.left, ListSort(column: .size, ascending: false))) // sorted again
        try await sides.settle()
        #expect(sides.names(.left) == ["big", "small", "empty", "file.txt"])
        workspace.reload(showing: [sides.left]) // a reload keeps that order
        try await sides.settle()
        #expect(sides.names(.left) == ["big", "small", "empty", "file.txt"])
    }

    @Test func navigatingStopsAMeasurementAndDropsItsResults() async throws {
        let sides = try makeSides()
        try await sides.settle()
        let workspace = sides.workspace
        workspace.perform(.measureFolderSizes(.left))
        workspace.perform(.navigate(.left, path: sides.right)) // before anything was measured
        #expect(sizes(sides).isEmpty && workspace.folderSizeWork[.left] == nil)
        try await sides.settle()
        #expect(sizes(sides).isEmpty)

        // Results already handed over, not yet shown, when the side goes elsewhere: dropped too.
        workspace.perform(.navigate(.left, path: sides.left))
        try await sides.settle()
        workspace.perform(.measureFolderSizes(.left))
        usleep(500_000) // the main thread is busy: the walk finishes meanwhile
        workspace.perform(.navigate(.left, path: sides.right))
        try await sides.settle()
        #expect(sizes(sides).isEmpty)

        // A new search drops them too: its results have other names.
        workspace.perform(.navigate(.left, path: sides.left))
        try await sides.settle()
        workspace.perform(.measureFolderSizes(.left))
        try await sides.settle()
        #expect(sizes(sides).count == 3)
        workspace.perform(.find(.left, pattern: "*"))
        #expect(sizes(sides).isEmpty)
        try await sides.settle()
        workspace.perform(.select(.left, ["big/inner"]))
        workspace.perform(.measureFolderSizes(.left)) // search results are measured where they are
        try await sides.settle()
        #expect(sizes(sides) == ["big/inner": .measured(3000)])
    }

    @Test func anotherVolumeBelowIsNotEntered() throws {
        let volume = try FindDiskImage()
        FileManager.default.createFile(atPath: volume.mountPoint + "/on-the-image", contents: Data(count: 50000))
        FileManager.default.createFile(atPath: volume.folder + "/here", contents: Data(count: 30))
        let measured = try #require(FolderSizes.measure(volume.folder, cancelled: CancellationFlag()))
        let image = try #require(
            try FileManager.default.attributesOfItem(atPath: volume.folder + "/volume.sparseimage")[.size] as? Int64
        )
        // The image file is counted, what is on the mounted image is not counted again.
        #expect(measured >= 30)
        #expect(measured < image + 30 + 50000)
        #expect(try #require(FolderSizes.measure(volume.mountPoint, cancelled: CancellationFlag())) >= 50000)
    }
}
