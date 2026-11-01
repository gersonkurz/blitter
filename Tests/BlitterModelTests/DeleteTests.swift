@testable import BlitterModel
import Foundation
import Testing

/// Delete Immediately (#17): asks first by default, deletes exactly what was confirmed, never
/// touches the Trash.
@MainActor
@Suite(.serialized)
struct DeleteTests {
    private func sidesWithFiles() async throws -> SidesOnDisk {
        let sides = try SidesOnDisk()
        sides.file("left/a.txt")
        sides.file("left/b.txt")
        sides.file("left/c.txt")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        return sides
    }

    @Test func deleteAsksFirstAndDeletesExactlyWhatWasConfirmed() async throws {
        let sides = try await sidesWithFiles()
        sides.workspace.perform(.select(.left, ["a.txt", "b.txt"]))
        sides.workspace.perform(.runAction("delete-immediately", .left))
        try await sides.settle()
        let request = try #require(sides.workspace.deleteRequest)
        #expect(request.paths == [sides.left + "/a.txt", sides.left + "/b.txt"])
        #expect(sides.onDisk("left") == ["a.txt", "b.txt", "c.txt"]) // nothing yet
        #expect(sides.workspace.jobs.isEmpty)

        // The selection changes while the question is open; the answer still means a and b.
        sides.workspace.perform(.select(.left, ["c.txt"]))
        sides.workspace.perform(.answerDelete(token: request.token, delete: true))
        try await sides.settle()
        #expect(sides.workspace.deleteRequest == nil)
        #expect(sides.onDisk("left") == ["c.txt"])
        #expect(sides.names(.left) == ["c.txt"])
        #expect(sides.onDisk("trash").isEmpty)
    }

    @Test func answeringNoKeepsEverything() async throws {
        let sides = try await sidesWithFiles()
        sides.workspace.perform(.select(.left, ["a.txt"]))
        sides.workspace.perform(.deleteSelection(.left))
        let request = try #require(sides.workspace.deleteRequest)
        sides.workspace.perform(.answerDelete(token: request.token, delete: false))
        try await sides.settle()
        #expect(sides.workspace.deleteRequest == nil)
        #expect(sides.onDisk("left") == ["a.txt", "b.txt", "c.txt"])
        #expect(sides.workspace.jobs.isEmpty)
    }

    /// An answer to an earlier question never deletes what a newer one names.
    @Test func anAnswerToAReplacedQuestionIsIgnored() async throws {
        let sides = try await sidesWithFiles()
        sides.workspace.perform(.select(.left, ["a.txt"]))
        sides.workspace.perform(.deleteSelection(.left))
        let first = try #require(sides.workspace.deleteRequest)
        sides.workspace.perform(.select(.left, ["b.txt"]))
        sides.workspace.perform(.deleteSelection(.left))
        let second = try #require(sides.workspace.deleteRequest)
        #expect(second.token != first.token)

        var changes = 0
        sides.workspace.onChange = { changes += 1 }
        sides.workspace.perform(.answerDelete(token: first.token, delete: true))
        try await sides.settle()
        #expect(changes == 0)
        #expect(sides.workspace.deleteRequest == second)
        #expect(sides.onDisk("left") == ["a.txt", "b.txt", "c.txt"])
    }

    @Test func withoutAskingDeletesAtOnce() async throws {
        let sides = try await sidesWithFiles()
        sides.workspace.perform(.select(.left, ["a.txt", "c.txt"]))
        sides.workspace.perform(.runAction("delete-immediately-without-asking", .left))
        #expect(sides.workspace.deleteRequest == nil)
        try await sides.settle()
        #expect(sides.onDisk("left") == ["b.txt"])
        #expect(sides.onDisk("trash").isEmpty)
    }

    @Test func theSettingCanTurnTheQuestionOff() async throws {
        let sides = try await sidesWithFiles()
        sides.workspace.settings.confirmDelete = false
        sides.workspace.perform(.select(.left, ["b.txt"]))
        sides.workspace.perform(.deleteSelection(.left))
        #expect(sides.workspace.deleteRequest == nil)
        try await sides.settle()
        #expect(sides.onDisk("left") == ["a.txt", "c.txt"])
    }

    @Test func nothingSelectedAsksNothingAndDeletesNothing() async throws {
        let sides = try await sidesWithFiles()
        var changes = 0
        sides.workspace.onChange = { changes += 1 }
        sides.workspace.perform(.deleteSelection(.left))
        sides.workspace.perform(.deleteSelectionWithoutAsking(.left))
        sides.workspace.perform(.runAction("delete-immediately", .left))
        try await sides.settle()
        #expect(changes == 0 && sides.workspace.deleteRequest == nil && sides.workspace.jobs.isEmpty)
        #expect(sides.onDisk("left") == ["a.txt", "b.txt", "c.txt"])
    }
}
