import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

/// #112 step 3: a search and a folder measuring are listed with the jobs while they run — what
/// they do, how far — and Cancel there stops them as their own Stop does. They run as before.
@MainActor
@Suite(.serialized)
struct BackgroundTaskTests {
    @Test func aSearchIsListedWhileItRunsAndGoneWhenItEnds() async throws {
        let sides = try SidesOnDisk()
        for folder in ["a", "b", "c"] {
            try FileManager.default.createDirectory(
                atPath: sides.left + "/" + folder,
                withIntermediateDirectories: true
            )
            sides.file("left/\(folder)/x.swift")
        }
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        sides.workspace.perform(.find(.left, pattern: "*.swift"))
        let task = try #require(sides.workspace.backgroundTasks.first)
        #expect(task.title == "Finding “*.swift” in “left”" && task.origin == nil)
        try await sides.settle()
        #expect(sides.workspace.backgroundTasks.isEmpty) // done: gone
        #expect(sides.names(.left).count == 3) // found as before
    }

    /// Cancel — here from another window, as the Jobs window does — stops a search that has
    /// found things already; what it found stays (#112 review).
    @Test func cancelStopsTheSearchAndKeepsWhatItFound() async throws {
        let sides = try SidesOnDisk()
        sides.file("left/a.txt", "a needle") // found at once
        // Read after it, and slowly: text first (a NUL there would make it binary, skipped), then
        // a large sparse tail of zeros to read through.
        let big = sides.left + "/z.log"
        #expect(FileManager.default.createFile(atPath: big, contents: Data(repeating: 0x78, count: 300_000)))
        #expect(truncate(big, 8 << 30) == 0)
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        let other = Workspace(sharingWith: sides.workspace, location: sides.right)
        sides.workspace.perform(.find(.left, pattern: "", containing: "needle"))
        let task = try #require(sides.workspace.backgroundTasks.first)
        for _ in 0 ..< 2000 where (sides.workspace.state(of: .left).find?.filesRead ?? 0) < 1 {
            try await Task.sleep(for: .milliseconds(1)) // a.txt read and found, z.bin being read
        }
        try #require(sides.workspace.state(of: .left).find?.isRunning == true) // in the middle
        other.perform(.cancelTask(task.id))
        #expect(sides.workspace.backgroundTasks.isEmpty)
        try await sides.settle()
        let find = try #require(sides.workspace.state(of: .left).find)
        #expect(!find.isRunning)
        #expect(sides.names(.left) == ["a.txt"]) // what it found stays
    }

    @Test func goingElsewhereEndsTheSearchsTask() throws {
        let sides = try SidesOnDisk()
        sides.workspace.perform(.find(.left, pattern: "*.swift"))
        #expect(!sides.workspace.backgroundTasks.isEmpty)
        sides.workspace.perform(.navigate(.left, path: sides.right))
        #expect(sides.workspace.backgroundTasks.isEmpty)
    }

    /// Measuring folder sizes: listed with how many are measured; Cancel stops it, as Stop does.
    @Test func measuringIsListedWithHowFarAndCancelStopsIt() async throws {
        let sides = try SidesOnDisk()
        for folder in ["one", "two", "zslow"] {
            try FileManager.default.createDirectory(
                atPath: sides.left + "/" + folder,
                withIntermediateDirectories: true
            )
            sides.file("left/\(folder)/f", "12345")
        }
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        let gate = DispatchSemaphore(value: 0)
        sides.workspace.measureFolder = { path, cancelled in
            if path.hasSuffix("/zslow") {
                gate.wait() // the last one: still measuring when cancelled
            } else {
                Thread.sleep(forTimeInterval: 0.25) // so each result is handed over on its own
            }
            return FolderSizes.measure(path, cancelled: cancelled)
        }
        sides.workspace.perform(.measureFolderSizes(.left))
        let task = try #require(sides.workspace.backgroundTasks.first)
        #expect(task.title == "Measuring 3 folders in “left”")
        for _ in 0 ..< 400 where sides.workspace.backgroundTasks.first?.progress.isEmpty != false {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(sides.workspace.backgroundTasks.first?.progress.hasSuffix("of 3 folders measured") == true)
        sides.workspace.perform(.cancelTask(task.id))
        #expect(sides.workspace.backgroundTasks.isEmpty)
        #expect(!sides.workspace.state(of: .left).folderSizes.values.contains(.measuring)) // as Stop leaves it
        gate.signal()

        sides.workspace.measureFolder = { path, cancelled in FolderSizes.measure(path, cancelled: cancelled) }
        sides.workspace.perform(.measureFolderSizes(.left))
        #expect(sides.workspace.backgroundTasks.count == 1)
        try await sides.settle()
        #expect(sides.workspace.backgroundTasks.isEmpty) // done: gone
    }

    /// #112 review: a second measuring, of two folders, says how far it is with them — not
    /// counting the sizes known from the first.
    @Test func aSecondMeasuringCountsOnlyItsOwnFolders() async throws {
        let sides = try SidesOnDisk()
        for folder in ["one", "two", "three"] {
            try FileManager.default.createDirectory(
                atPath: sides.left + "/" + folder,
                withIntermediateDirectories: true
            )
            sides.file("left/\(folder)/f", "12345")
        }
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        sides.workspace.perform(.measureFolderSizes(.left)) // all three
        try await sides.settle()
        let held = DispatchSemaphore(value: 0)
        sides.workspace.measureFolder = { path, cancelled in
            if path.hasSuffix("/two") {
                held.wait()
            } else {
                Thread.sleep(forTimeInterval: 0.25)
            }
            return FolderSizes.measure(path, cancelled: cancelled)
        }
        sides.workspace.perform(.select(.left, ["one", "two"]))
        sides.workspace.perform(.measureFolderSizes(.left))
        #expect(sides.workspace.backgroundTasks.first?.title == "Measuring 2 folders in “left”")
        for _ in 0 ..< 400 where sides.workspace.backgroundTasks.first?.progress.isEmpty != false {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(sides.workspace.backgroundTasks.first?.progress == "1 of 2 folders measured")
        held.signal()
        try await sides.settle()
    }

    /// Another window's tasks are listed with which window; closing that window ends them, and
    /// every other window is told at once (#112 review).
    @Test func closingAWindowEndsItsTasksAndTellsTheOthers() throws {
        let sides = try SidesOnDisk()
        let second = Workspace(sharingWith: sides.workspace, location: sides.left)
        second.perform(.find(.left, pattern: "*.swift"))
        #expect(sides.workspace.backgroundTasks.first?.origin == "From window 2")
        var told = 0
        sides.workspace.onChange = { told += 1 }
        second.windowClosed()
        #expect(sides.workspace.backgroundTasks.isEmpty && told > 0)
    }
}
