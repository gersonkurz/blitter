import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

/// #112 step 2: a job says where it came from — automation and its client, or which window when
/// there is more than one — and Start Now is a command.
@MainActor
@Suite(.serialized)
struct JobOriginTests {
    @Test func aJobFromAutomationSaysSoAndNamesTheClient() async throws {
        let gate = DispatchSemaphore(value: 0)
        let sides = try SidesOnDisk(gate: gate)
        sides.file("left/a.txt")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        sides.workspace.perform(.select(.left, ["a.txt"]))
        let running = Task {
            try await sides.workspace.runAutomated(["action": "copy-to-other-side", "side": "left"],
                                                   client: "Claude Code")
        }
        for _ in 0 ..< 400 where sides.workspace.automationConfirmation == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let asked = try #require(sides.workspace.automationConfirmation)
        sides.workspace.perform(.answerAutomation(token: asked.token, allow: true))
        for _ in 0 ..< 400 where sides.workspace.jobs.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(sides.workspace.jobs.first?.origin == "From automation (Claude Code)")
        #expect(sides.workspace.automationClient == nil) // only while its command is carried out
        gate.signal()
        _ = try await running.value

        sides.workspace.perform(.newFolder(.left)) // the user, in the only window
        for _ in 0 ..< 400 where sides.workspace.jobs.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(sides.workspace.jobs.last?.origin == nil)
        gate.signal()
    }

    @Test func withSeveralWindowsAJobNamesItsWindow() throws {
        let sides = try SidesOnDisk()
        let second = Workspace(sharingWith: sides.workspace, location: sides.left)
        #expect(sides.workspace.jobOrigin == "From window 1" && second.jobOrigin == "From window 2")
        _ = second // the second window stays open until here
    }

    @Test func startNowIsACommand() async throws {
        let gate = DispatchSemaphore(value: 0)
        let sides = try SidesOnDisk(gate: gate)
        sides.file("left/a.txt")
        sides.file("left/b.txt")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        sides.workspace.perform(.select(.left, ["a.txt"]))
        sides.workspace.perform(.runAction("copy-to-other-side", .left))
        sides.workspace.perform(.select(.left, ["b.txt"]))
        sides.workspace.perform(.runAction("copy-to-other-side", .left))
        let second = try #require(sides.workspace.jobs.last?.id)
        for _ in 0 ..< 400 where !sides.workspace.canStartJobNow(second) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(sides.workspace.jobs.last?.state == .queued)
        sides.workspace.perform(.startJobNow(second))
        #expect(sides.workspace.jobs.last?.state == .running)
        gate.signal()
        gate.signal()
    }
}
