import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

/// The automation socket's requests (#58), answered by a workspace on real files.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) // a request left waiting fails, never hangs
struct AutomationTests {
    private func makeSides() async throws -> SidesOnDisk {
        let sides = try SidesOnDisk()
        try FileManager.default.createDirectory(atPath: sides.left + "/docs", withIntermediateDirectories: false)
        for name in ["a.txt", "b.txt", "c.txt"] {
            sides.file("left/" + name, name)
        }
        try await sides.settle()
        return sides
    }

    private func call(_ workspace: Workspace, _ method: String, _ params: JSONValue = [:],
                      id: JSONValue = 1) async throws -> JSONValue
    {
        let request: JSONValue = ["jsonrpc": "2.0", "id": id, "method": .string(method), "params": params]
        let reply = try #require(await workspace.handleAutomation(request.line, client: "test (pid 1)"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))
    }

    private func errorCode(_ reply: JSONValue) -> Int? {
        reply["error"]?["code"]?.int
    }

    @Test func framingAndErrors() async throws {
        let sides = try await makeSides()
        let workspace = sides.workspace
        #expect(try await call(workspace, "hello")["result"] == ["app": "Blitter", "protocol": 1])
        #expect(try await call(workspace, "hello", id: "x")["id"] == "x")
        func raw(_ line: String) async -> String? {
            await workspace.handleAutomation(line, client: "test")
        }
        #expect(await raw("{nope")?.contains("-32700") == true)
        // Not JSON-RPC 2.0: no version, a wrong version, an id that is no id, a batch.
        #expect(await raw(#"{"id":1,"method":"hello"}"#)?.contains(#""code":-32600"#) == true)
        #expect(await raw(#"{"jsonrpc":"1.0","id":7,"method":"hello"}"#)?.contains(#""id":7"#) == true)
        #expect(await raw(#"{"jsonrpc":"2.0","id":{"x":1},"method":"hello"}"#)?.contains(#""id":null"#) == true)
        #expect(await raw(#"[{"jsonrpc":"2.0","id":1,"method":"hello"}]"#)?.contains("-32600") == true)
        #expect(await raw(#"{"jsonrpc":"2.0","id":1,"method":"hello","params":[1]}"#)?.contains("-32602") == true)
        // A notification is carried out, and not answered.
        #expect(await raw(#"{"jsonrpc":"2.0","method":"select","params":{"side":"left","names":["b.txt"]}}"#) == nil)
        #expect(workspace.state(of: .left).selection == ["b.txt"])
        #expect(await raw(#"{"jsonrpc":"2.0","method":"no-such"}"#) == nil)
        #expect(await raw(#"{"jsonrpc":"2.0","method":"select","params":[]}"#) == nil) // not even errors
        workspace.perform(.select(.left, []))
        #expect(try await errorCode(call(workspace, "format-disk")) == -32601)
        #expect(try await errorCode(call(workspace, "listing", ["side": "up"])) == -32602)
        #expect(try await errorCode(call(workspace, "listing", ["side": 123])) == -32602) // not the active side
        #expect(try await errorCode(call(workspace, "select", ["side": "left", "names": [1, "a.txt"]])) == -32602)
        #expect(try await errorCode(call(workspace, "run", ["action": "delete-immediately"])) == 1)
        #expect(try await errorCode(call(workspace, "run", ["action": "copy-path"])) == 1)
        #expect(try await errorCode(call(workspace, "run", ["action": "move-to-trash"])) == 2) // nothing selected
    }

    @Test func stateListingActionsAndViewChanges() async throws {
        let sides = try await makeSides()
        let workspace = sides.workspace
        let state = try await call(workspace, "state")["result"]
        #expect(state?["activeSide"] == "left")
        #expect(state?["sides"]?["left"]?["location"]?.string == sides.left)
        #expect(state?["sides"]?["left"]?["status"] == "loaded" && state?["sides"]?["left"]?["items"] == 4)

        let page = try await call(workspace, "listing", ["side": "left", "offset": 1, "limit": 2])["result"]
        #expect(page?["total"] == 4 && page?["entries"]?.array?.compactMap { $0["name"]?.string } == ["a.txt", "b.txt"])
        #expect(page?["entries"]?.array?.first?["kind"] == "file" && page?["entries"]?.array?.first?["size"] == 5)

        let actions = try await call(workspace, "actions", ["side": "left"])["result"]?.array ?? []
        let ids = actions.compactMap { $0["id"]?.string }
        #expect(ids.contains("move-to-trash") && ids.contains("folder-sizes"))
        #expect(!ids.contains("delete-immediately") && !ids.contains("copy-path") && !ids.contains("batch-rename"))
        #expect(actions.first { $0["id"] == "move-to-trash" }?["effect"] == "changes")

        let selected = try await call(workspace, "select", ["side": "left", "names": ["a.txt", "docs", "nope"]])
        #expect(selected["result"]?["selection"] == ["a.txt", "docs"] && selected["result"]?["notListed"] == ["nope"])
        #expect(workspace.state(of: .left).selection == ["a.txt", "docs"])

        let went = try await call(workspace, "navigate", [
            "side": "right",
            "path": .string(sides.left + "/docs"),
        ])["result"]
        #expect(went?["status"] == "loaded" && went?["listedLocation"]?.string == sides.left + "/docs")
        _ = try await call(workspace, "activate", ["side": "right"])
        #expect(workspace.activeSide == .right)
    }

    @Test func viewActionsRunAtOnceOthersAfterAllow() async throws {
        let sides = try await makeSides()
        let workspace = sides.workspace
        _ = try await call(workspace, "select", ["side": "left", "names": ["docs"]])
        let sized = try await call(workspace, "run", ["action": "folder-sizes", "side": "left"])
        #expect(sized["result"]?["done"] == true && workspace.automationConfirmation == nil)

        _ = try await call(workspace, "select", ["side": "left", "names": ["a.txt", "b.txt"]])
        let preview = try await call(workspace, "preview", ["action": "move-to-trash", "side": "left"])["result"]
        #expect(preview?["items"] == .array([.string(sides.left + "/a.txt"), .string(sides.left + "/b.txt")]))
        #expect(preview?["needsConfirmation"] == true)
        #expect(sides.names(.left).count == 4) // a preview changes nothing

        let running = Task { try await call(workspace, "run", ["action": "move-to-trash", "side": "left"]) }
        let asked = try await waitForConfirmation(workspace)
        #expect(asked.client == "test (pid 1)" && asked.plan.items.count == 2 && asked.plan.effect == .changes)
        workspace.perform(.answerAutomation(token: asked.token, allow: true))
        let done = try await running.value
        #expect(done["result"]?["jobs"]?.array?.first?["state"] == "finished")
        #expect(done["result"]?["jobs"]?.array?.first?["errors"] == [])
        try await sides.settle()
        #expect(sides.names(.left) == ["docs", "c.txt"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: sides.trash).sorted() == ["a.txt", "b.txt"])
    }

    @Test func deniedChangedBusyAndGone() async throws {
        let sides = try await makeSides()
        let workspace = sides.workspace
        _ = try await call(workspace, "select", ["side": "left", "names": ["a.txt"]])
        let run: JSONValue = ["action": "move-to-trash", "side": "left"]

        var running = Task { try await call(workspace, "run", run) }
        var asked = try await waitForConfirmation(workspace)
        // Only one question at a time.
        #expect(try await errorCode(call(workspace, "run", ["action": "copy-to-other-side", "side": "left"])) == 5)
        workspace.perform(.answerAutomation(token: asked.token, allow: false))
        #expect(try await errorCode(running.value) == 3)

        // The selection changes while Blitter asks: allowing runs nothing.
        running = Task { try await call(workspace, "run", run) }
        asked = try await waitForConfirmation(workspace)
        workspace.perform(.select(.left, ["b.txt"]))
        workspace.perform(.answerAutomation(token: asked.token, allow: true))
        #expect(try await errorCode(running.value) == 4)

        // The client goes away: the question is withdrawn.
        running = Task { try await call(workspace, "run", run) }
        asked = try await waitForConfirmation(workspace)
        running.cancel()
        #expect(try await errorCode(running.value) == 3)
        #expect(workspace.automationConfirmation == nil)
        try await sides.settle()
        #expect(sides.names(.left).count == 4 && workspace.jobs.isEmpty)
    }

    private func waitForConfirmation(_ workspace: Workspace) async throws -> AutomationConfirmation {
        for _ in 0 ..< 400 where workspace.automationConfirmation == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        return try #require(workspace.automationConfirmation)
    }

    /// The settings change while Blitter asks: what would run then is not what was shown, even
    /// when only the command line's argument split or the diff tool changed (#58 review).
    @Test func aChangedDefinitionWhileAskedRunsNothing() async throws {
        let sides = try await makeSides()
        let workspace = sides.workspace
        let launched = LaunchRecorder()
        workspace.launchTool = { arguments, _ in launched.record(arguments) }
        func tool(_ command: [String]) -> Tool {
            Tool(id: "probe", title: "Probe", app: "", scope: .folder, command: command)
        }
        workspace.settings.tools = [tool(["/bin/echo", "a b"])]
        for change in [["/bin/echo", "a", "b"], ["/usr/bin/false"]] {
            let running = Task { try await call(workspace, "run", ["action": "probe", "side": "left"]) }
            let asked = try await waitForConfirmation(workspace)
            workspace.settings.tools = [tool(change)]
            workspace.perform(.answerAutomation(token: asked.token, allow: true))
            #expect(try await errorCode(running.value) == 4)
            workspace.settings.tools = [tool(["/bin/echo", "a b"])]
        }
        #expect(workspace.jobs.isEmpty) // nothing ran

        _ = try await call(workspace, "select", ["side": "left", "names": ["a.txt", "b.txt"]])
        workspace.settings.diffTool = ["/usr/bin/opendiff", "{left}", "{right}"]
        let comparing = Task { try await call(workspace, "run", ["action": "compare-files", "side": "left"]) }
        let asked = try await waitForConfirmation(workspace)
        workspace.settings.diffTool = ["/usr/local/bin/other", "{left}", "{right}"]
        workspace.perform(.answerAutomation(token: asked.token, allow: true))
        #expect(try await errorCode(comparing.value) == 4)
        try await Task.sleep(for: .milliseconds(100))
        #expect(launched.calls.isEmpty)
    }
}

/// Records the diff tool launches a test would make.
final class LaunchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []

    var calls: [[String]] {
        lock.withLock { recorded }
    }

    func record(_ arguments: [String]) {
        lock.withLock { recorded.append(arguments) }
    }
}
