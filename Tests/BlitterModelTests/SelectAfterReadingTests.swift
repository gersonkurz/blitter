@testable import BlitterModel
import Foundation
import Testing

/// #70 review: what a job made is selected after the listing is read again, also when a fast
/// filter would hide it: the filter ends.
@MainActor
@Suite(.serialized)
struct SelectAfterReadingTests {
    @Test func aFilterThatHidesTheNewItemEnds() async throws {
        let sides = try SidesOnDisk()
        sides.file("left/existing.txt")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        sides.workspace.perform(.setQuickFilter(.left, QuickFilter("existing", mode: .filter)))
        try await sides.settle()
        try FileManager.default.createDirectory(atPath: sides.left + "/project", withIntermediateDirectories: false)
        sides.workspace.perform(.selectAfterReading(folder: sides.left, names: ["project"]))
        try await sides.settle()
        #expect(sides.workspace.state(of: .left).quickFilter == nil)
        #expect(sides.names(.left) == ["project", "existing.txt"])
        #expect(sides.workspace.state(of: .left).selection == ["project"])
    }
}
