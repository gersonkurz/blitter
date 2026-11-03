@testable import BlitterCore
import Foundation
import Testing

/// The `blitter` tool (#59): its command line, its client, and the built tool itself against a
/// test server.
@Suite(.serialized)
struct AutomationClientTests {
    private let folder = NSTemporaryDirectory() + "bc-" + String(UUID().uuidString.prefix(8))
    private var path: String {
        folder + "/s.sock"
    }

    @Test func commandLinesBecomeRequests() throws {
        func request(_ words: String) throws -> String {
            let (method, params) = try AutomationCommandLine.request(words.split(separator: " ").map(String.init))
            return method + " " + params.line
        }
        #expect(try request("state") == "state {}")
        #expect(try request("listing") == "listing {}")
        #expect(try request("listing right --limit 5 --offset 10") ==
            #"listing {"limit":5,"offset":10,"side":"right"}"#)
        #expect(try request("actions left") == #"actions {"side":"left"}"#)
        #expect(try request("navigate left /tmp") == #"navigate {"path":"/tmp","side":"left"}"#)
        #expect(try request("select right a.txt b.txt") == #"select {"names":["a.txt","b.txt"],"side":"right"}"#)
        #expect(try request("select right") == #"select {"names":[],"side":"right"}"#)
        #expect(try request("activate right") == #"activate {"side":"right"}"#)
        #expect(try request("preview move-to-trash") == #"preview {"action":"move-to-trash"}"#)
        #expect(try request("run new-folder left") == #"run {"action":"new-folder","side":"left"}"#)
        #expect(try AutomationCommandLine.request(["call", "listing", #"{"side": "left"}"#]).params == ["side": "left"])
        for wrong in ["", "frobnicate", "navigate left", "listing up", "listing --limit x", "run", "call x [1]",
                      "state now", "select"]
        {
            #expect(throws: AutomationCommandLine.Usage.self) {
                try AutomationCommandLine.request(wrong.split(separator: " ").map(String.init))
            }
        }
    }

    /// A server that answers like Blitter: `state` with a result, anything else with an error.
    private func startServer() throws -> LineSocketServer {
        let server = LineSocketServer(path: path) { line, _ in
            let request = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            let id = request?["id"] ?? .null
            guard request?["method"] == "state" else {
                return JSONValue.object(["jsonrpc": "2.0", "id": id,
                                         "error": ["code": 2, "message": "does not fit"]]).line
            }
            return JSONValue.object(["jsonrpc": "2.0", "id": id, "result": ["activeSide": "left"]]).line
        }
        try server.start()
        return server
    }

    /// Failing to connect closes the socket once: nothing leaks over many tries (#59 review).
    @Test func failedConnectsLeaveNothingOpen() {
        func openDescriptors() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
        }
        let before = openDescriptors()
        for _ in 0 ..< 200 {
            _ = try? AutomationClient(path: folder + "/none.sock")
        }
        #expect(openDescriptors() == before)
    }

    /// A reply for another id (a stale one) is passed over until the right one comes.
    @Test func anAnswerForAnotherRequestIsSkipped() throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = LineSocketServer(path: path) { line, _ in
            let id = (try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)))?["id"] ?? .null
            let stale = JSONValue.object(["jsonrpc": "2.0", "id": 99, "result": "stale"]).line
            return stale + "\n" + JSONValue.object(["jsonrpc": "2.0", "id": id, "result": "fresh"]).line
        }
        try server.start()
        defer { server.stop() }
        let client = try AutomationClient(path: path)
        #expect(try client.call("state")["result"] == "fresh")
        #expect(try client.call("state")["result"] == "fresh") // the next one too
    }

    @Test func theClientMatchesAnswersToRequests() throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try startServer()
        defer { server.stop() }
        let client = try AutomationClient(path: path)
        #expect(try client.call("state")["result"] == ["activeSide": "left"])
        #expect(try client.call("run", ["action": "x"])["error"]?["code"] == 2)
        #expect(try client.call("state")["id"] == 3) // ids count up
        #expect(throws: AutomationClient.Failure.notRunning(folder + "/none.sock")) {
            try AutomationClient(path: folder + "/none.sock")
        }
    }

    /// The tool as built: output, and exit status 0, 1 or 2.
    @Test func theBuiltTool() throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try startServer()
        defer { server.stop() }
        var result = try runTool(["state"])
        #expect(result.status == 0 && result.output.contains(#""activeSide" : "left""#))
        result = try runTool(["run", "move-to-trash"])
        #expect(result.status == 1 && result.errors.contains("does not fit (code 2)"))
        result = try runTool(["listing", "up"])
        #expect(result.status == 1 && result.errors.contains("SIDE is left or right"))
        result = try runTool(["help"])
        #expect(result.status == 0 && result.output.contains("usage: blitter"))
        server.stop()
        result = try runTool(["state"])
        #expect(result.status == 2 && result.errors.contains("Blitter is not running"))
    }

    private struct ToolResult {
        let status: Int32
        let output: String
        let errors: String
    }

    private func runTool(_ arguments: [String]) throws -> ToolResult {
        let tests = try #require(Bundle.allBundles.first { $0.bundlePath.hasSuffix("BlitterCoreTests.xctest") })
        let tool = (tests.bundlePath as NSString).deletingLastPathComponent + "/blitter"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = ["BLITTER_SOCKET": path]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let text = { (pipe: Pipe) in
            String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        return ToolResult(status: process.terminationStatus, output: text(output), errors: text(errors))
    }
}
