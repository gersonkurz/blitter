import BlitterCore
@testable import BlitterModel
import Foundation
import Synchronization
import Testing

/// Find (#48): what its first review found.
@MainActor
@Suite(.serialized)
struct FindReviewTests {
    /// left/ holds a/one.txt, a/b/two.txt, top.txt.
    private func tree() throws -> SidesOnDisk {
        let sides = try SidesOnDisk()
        try FileManager.default.createDirectory(atPath: sides.left + "/a/b", withIntermediateDirectories: true)
        for file in ["left/a/one.txt", "left/a/b/two.txt", "left/top.txt"] {
            sides.file(file)
        }
        return sides
    }

    private func everything(_ sides: SidesOnDisk) async throws {
        try await sides.settle()
        sides.workspace.perform(.find(.left, pattern: "*"))
        try await sides.settle()
        #expect(sides.names(.left).sorted() == ["a", "a/b", "a/b/two.txt", "a/one.txt", "top.txt"])
        sides.workspace.perform(.select(.left, Set(sides.names(.left))))
    }

    /// A folder and what is in it, both selected: each is moved, trashed or deleted once, with it.
    @Test func overlappingResultsAreMovedOnce() async throws {
        let sides = try tree()
        try await everything(sides)
        sides.workspace.perform(.moveToOtherSide)
        try await sides.settle()
        #expect(sides.workspace.jobs.isEmpty) // no errors: nothing was missing
        #expect(sides.onDisk("right") == ["a", "top.txt"])
        #expect(sides.onDisk("right/a") == ["b", "one.txt"] && sides.onDisk("right/a/b") == ["two.txt"])
        #expect(sides.onDisk("left").isEmpty)
    }

    /// A drag or paste hands over paths, not a selection: the same, at the job queue.
    @Test func overlappingDraggedPathsAreMovedOnce() async throws {
        let sides = try tree()
        try await sides.settle()
        let paths = [sides.left + "/a/b/two.txt", sides.left + "/a", sides.left + "/a/one.txt"]
        sides.workspace.perform(.moveItems(paths, toFolder: sides.right))
        try await sides.settle()
        #expect(sides.workspace.jobs.isEmpty && sides.onDisk("right") == ["a"])
        #expect(sides.onDisk("right/a") == ["b", "one.txt"] && sides.onDisk("left") == ["top.txt"])
    }

    @Test func overlappingResultsAreCopiedOnceAndTrashedOnce() async throws {
        let sides = try tree()
        try await everything(sides)
        sides.workspace.perform(.copyToOtherSide)
        try await sides.settle()
        #expect(sides.workspace.jobs.isEmpty && sides.onDisk("right") == ["a", "top.txt"]) // no loose copies
        sides.workspace.perform(.trashSelection(.left))
        try await sides.settle()
        #expect(sides.workspace.jobs.isEmpty && sides.onDisk("trash") == ["a", "top.txt"])
        #expect(sides.onDisk("left").isEmpty)
    }

    @Test func overlappingResultsAreDeletedOnce() async throws {
        let sides = try tree()
        try await everything(sides)
        sides.workspace.perform(.deleteSelection(.left))
        #expect(sides.workspace.deleteRequest?.paths == [sides.left + "/a", sides.left + "/top.txt"]) // asks for two
        sides.workspace.perform(.deleteSelectionWithoutAsking(.left))
        try await sides.settle()
        #expect(sides.workspace.jobs.isEmpty && sides.onDisk("left").isEmpty)
    }

    /// The working copy of a result is found, though neither it nor any folder on the way is a
    /// result; each folder is looked at once.
    @Test func theWorkingCopiesOfResultsAreFound() async throws {
        let sides = try SidesOnDisk()
        let repo = sides.left + "/group/repo"
        try FileManager.default.createDirectory(atPath: repo + "/src/deep", withIntermediateDirectories: true)
        sides.file("left/group/repo/src/main.swift")
        sides.file("left/group/repo/src/deep/more.swift")
        sides.file("left/group/repo/src/other.swift")
        let looked = Mutex<[String]>([])
        sides.workspace.gitAccess = GitAccess(repositoryRoot: { _ in nil }, isRepositoryRoot: { path in
            looked.withLock { $0.append(path) }
            return path == repo
        }, status: { _, _ in GitRepoStatus(changed: ["src/main.swift"]) })
        try await sides.settle()
        looked.withLock { $0 = [] }
        sides.workspace.perform(.find(.left, pattern: "*.swift"))
        try await sides.settle()
        #expect(sides.workspace.gitRepositories[repo] != nil)
        #expect(sides.workspace.workingCopyRoot(containing: repo + "/src/main.swift") == repo)
        #expect(sides.workspace.gitState(of: repo + "/src/main.swift", isFolder: false) == .modified)
        let checks = looked.withLock { $0 }
        #expect(Set(checks) == [repo + "/src/deep", repo + "/src", repo])
        #expect(checks.count == Set(checks).count) // each once, the results' order whatever it is
    }

    /// The path field shows the search; Return on it unchanged changes nothing, and that text
    /// pasted elsewhere is no path either (round 2: a folder or pattern may hold "?name=").
    @Test func theShownSearchIsNoPath() async throws {
        let sides = try tree()
        try await sides.settle()
        sides.workspace.perform(.find(.left, pattern: "*?name=x*"))
        try await sides.settle()
        let shown = try #require(sides.workspace.state(of: .left).find?.displayLocation)
        #expect(shown == "search://" + sides.left + "?name=*?name=x*")
        sides.workspace.perform(.navigate(.left, path: shown))
        #expect(sides.workspace.state(of: .left).find?.isRunning == false) // not even run again
        #expect(sides.workspace.state(of: .left).location == sides.left)
        let history = sides.workspace.state(of: .right).backStack
        sides.workspace.perform(.navigate(.right, path: shown)) // pasted on the other side
        #expect(sides.workspace.state(of: .right).location == sides.right)
        #expect(sides.workspace.state(of: .right).find == nil && sides.workspace.state(of: .right).backStack == history)
    }

    /// Back or Forward with nowhere to go leaves the search as it is.
    @Test func navigationWithNowhereToGoKeepsTheSearch() async throws {
        let sides = try tree()
        try await sides.settle()
        sides.workspace.perform(.find(.left, pattern: "*.txt"))
        try await sides.settle()
        sides.workspace.perform(.goForward(.left)) // the search cleared the forward history
        #expect(sides.workspace.state(of: .left).find != nil)
        #expect(!sides.workspace.canRun("rename", on: .left))
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        #expect(sides.names(.left).sorted() == ["a/b/two.txt", "a/one.txt", "top.txt"]) // still the results
    }

    /// A volume mounted below the folder is not searched; a link to a volume, opened and
    /// searched, is searched where it leads.
    @Test func volumesBelowAreLeftOutAndALinkedRootIsSearched() async throws {
        let volume = try FindDiskImage()
        try FileManager.default.createDirectory(
            atPath: volume.mountPoint + "/inner",
            withIntermediateDirectories: false
        )
        FileManager.default.createFile(atPath: volume.mountPoint + "/inner/deep.txt", contents: Data("x".utf8))
        let sides = try SidesOnDisk()
        try await sides.settle()
        sides.workspace.perform(.navigate(.left, path: volume.folder))
        try await sides.settle()
        sides.workspace.perform(.find(.left, pattern: "*"))
        try await sides.settle()
        #expect(sides.names(.left).contains("mount"))
        #expect(!sides.names(.left).contains { $0.hasPrefix("mount/") }) // another volume: not entered

        try FileManager.default.createSymbolicLink(atPath: sides.left + "/link", withDestinationPath: volume.mountPoint)
        sides.workspace.perform(.navigate(.left, path: sides.left + "/link"))
        try await sides.settle()
        sides.workspace.perform(.find(.left, pattern: "*.txt"))
        try await sides.settle()
        #expect(sides.names(.left) == ["inner/deep.txt"]) // below the link's volume too
    }
}

/// Content search (#49): files holding a text, with the name as a pre-filter.
@MainActor
@Suite(.serialized)
struct FindContentsTests {
    @Test func filesContainingATextAreFound() async throws {
        let sides = try SidesOnDisk()
        try FileManager.default.createDirectory(atPath: sides.left + "/hello", withIntermediateDirectories: false)
        sides.file("left/a.txt", "Hello world")
        sides.file("left/hello/b.md", "say HELLO")
        sides.file("left/c.txt", "nothing here")
        FileManager.default.createFile(atPath: sides.left + "/d.bin", contents: Data([0x68, 0x00]) + Data("hello".utf8))
        try await sides.settle()
        sides.workspace.perform(.find(.left, pattern: "*.txt", containing: "hello"))
        try await sides.settle()
        #expect(sides.names(.left) == ["a.txt"])
        #expect(sides.workspace.state(of: .left).find?.filesRead == 2) // only the names that match are read
        #expect(sides.workspace.state(of: .left).find?.displayLocation
            == "search://" + sides.left + "?name=*.txt&contains=hello")

        sides.workspace.perform(.find(.left, pattern: "", containing: "hello")) // any name
        try await sides.settle()
        // Not the folder "hello" (a folder holds no text), not the binary file.
        #expect(sides.names(.left).sorted() == ["a.txt", "hello/b.md"])
        #expect(sides.workspace.state(of: .left).find?.filesRead == 4)

        sides.workspace.perform(.find(.left, pattern: "a*", containing: "   ")) // only spaces: names only
        try await sides.settle()
        #expect(sides.names(.left) == ["a.txt"] && sides.workspace.state(of: .left).find?.contents == "")
    }
}

/// #49 review: inside one folder, results and counts come as the files are read, and Stop
/// opens no further file.
struct FindContentsStreamingTests {
    private func folder(files: Int) throws -> String {
        let path = FileManager.default.temporaryDirectory.path + "/BlitterContents-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        for index in 0 ..< files {
            FileManager.default.createFile(atPath: path + "/f\(index).txt", contents: Data("needle \(index)".utf8))
        }
        return path
    }

    @Test func resultsComeBetweenTheFilesOfOneFolder() throws {
        let path = try folder(files: 5)
        defer { try? FileManager.default.removeItem(atPath: path) }
        var batches: [FindBatch] = []
        FileFind.walk(root: path, matcher: QuickFilter.Matcher("*", wholeName: true), contents: "needle",
                      includeHidden: false, cancelled: CancellationFlag(), interval: 0) { batches.append($0) }
        #expect(batches.map(\.filesRead) == [1, 2, 3, 4, 5, 5, 5]) // after each file, the folder, the end
        #expect(batches[0].entries.count == 1 && batches[0].foldersSearched == 1) // the first before the rest
        #expect(batches.flatMap(\.entries).count == 5)
    }

    @Test func stopOpensNoFurtherFile() throws {
        let path = try folder(files: 50)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let cancelled = CancellationFlag()
        var batches: [FindBatch] = []
        FileFind.walk(root: path, matcher: QuickFilter.Matcher("*", wholeName: true), contents: "needle",
                      includeHidden: false, cancelled: cancelled, interval: 0)
        { batch in
            batches.append(batch)
            cancelled.set() // Stop, once the first file was read
        }
        #expect(batches.last?.filesRead == 1)
    }
}

/// A small APFS volume, mounted below a temporary folder for one test and detached afterwards.
final class FindDiskImage {
    let folder: String
    let mountPoint: String

    init(fileSystem: String = "APFS") throws {
        folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
            + "/BlitterFindVolume-" + UUID().uuidString
        mountPoint = folder + "/mount"
        try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
        try Self.hdiutil(["create", "-quiet", "-size", "16m", "-fs", fileSystem, "-volname", "BlitterTest", "-type",
                          "SPARSE", folder + "/volume"])
        try Self.hdiutil(["attach", "-quiet", "-nobrowse", "-noautoopen", "-noverify", "-mountpoint", mountPoint,
                          folder + "/volume.sparseimage"])
    }

    deinit {
        try? Self.hdiutil(["detach", "-quiet", "-force", mountPoint])
        try? FileManager.default.removeItem(atPath: folder)
    }

    private static func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw POSIXError(.EIO)
        }
    }
}
