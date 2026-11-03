@testable import BlitterCore
import Foundation
import Testing

/// `blitter mcp` (#60): MCP messages in, Blitter's socket behind them.
@Suite(.serialized)
struct MCPServerTests {
    private func decode(_ line: String?) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(#require(line).utf8))
    }

    private func message(_ method: String, id: JSONValue? = 1, _ params: JSONValue = [:]) -> String {
        var object: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method), "params": params]
        object["id"] = id
        return JSONValue.object(object).line
    }

    @Test func handshakeToolsAndNotifications() throws {
        let server = MCPServer { _, _ in ["result": [:]] }
        var reply = try decode(server.handle(message("initialize", ["protocolVersion": "2025-03-26"])))
        #expect(reply["result"]?["protocolVersion"] == "2025-03-26")
        #expect(reply["result"]?["capabilities"]?["tools"] == [:])
        #expect(reply["result"]?["serverInfo"]?["name"] == "blitter")
        reply = try decode(server.handle(message("initialize", ["protocolVersion": "1999-01-01"])))
        #expect(reply["result"]?["protocolVersion"] == "2025-06-18") // one it knows
        #expect(server.handle(message("notifications/initialized", id: nil)) == nil)
        #expect(try decode(server.handle(message("ping")))["result"] == [:])
        #expect(try decode(server.handle(message("resources/list")))["error"]?["code"] == -32601)
        #expect(try decode(server.handle("{oops"))["error"]?["code"] == -32700)

        let tools = try decode(server.handle(message("tools/list")))["result"]?["tools"]?.array ?? []
        #expect(tools.compactMap { $0["name"]?.string }
            == ["state", "listing", "actions", "navigate", "select", "activate", "preview", "run"])
        let run = try #require(tools.first { $0["name"] == "run" })
        #expect(run["inputSchema"]?["required"] == ["action"])
        #expect(run["inputSchema"]?["properties"]?["side"]?["enum"] == ["left", "right"])
    }

    @Test func toolCallsGoToBlitter() throws {
        var asked: [(String, JSONValue)] = []
        let server = MCPServer { method, params in
            asked.append((method, params))
            switch method {
            case "state": return ["result": ["activeSide": "left"]]
            case "run": return ["error": ["code": 3, "message": "Denied in Blitter."]]
            default: throw AutomationClient.Failure.notRunning("/sock")
            }
        }
        func call(_ name: String, _ arguments: JSONValue = [:]) throws -> JSONValue {
            try decode(server.handle(message("tools/call", ["name": .string(name), "arguments": arguments])))
        }
        var reply = try call("state")
        #expect(reply["result"]?["isError"] == false)
        #expect(reply["result"]?["content"]?.array?.first?["text"]?.string?.contains(#""activeSide" : "left""#) == true)
        reply = try call("run", ["action": "move-to-trash", "side": "left"])
        #expect(reply["result"]?["isError"] == true)
        #expect(reply["result"]?["content"]?.array?.first?["text"] == "Denied in Blitter. (code 3)")
        #expect(asked.last?.0 == "run" && asked.last?.1 == ["action": "move-to-trash", "side": "left"])
        reply = try call("listing")
        #expect(reply["result"]?["content"]?.array?
            .first?["text"] == "Blitter is not running. Start it, then try again.")
        #expect(try call("format-disk")["error"]?["code"] == -32602)
        #expect(try decode(server.handle(message("tools/call", ["name": "state", "arguments": [1]])))["error"]?["code"]
            == -32602)
    }

    /// The built tool: `blitter mcp` over stdin and stdout, a test server as Blitter.
    @Test func theBuiltToolSpeaksMCP() throws {
        let folder = NSTemporaryDirectory() + "bm-" + String(UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let socket = folder + "/s.sock"
        let blitter = LineSocketServer(path: socket) { line, _ in
            let id = (try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)))?["id"] ?? .null
            return JSONValue.object(["jsonrpc": "2.0", "id": id, "result": ["activeSide": "right"]]).line
        }
        try blitter.start()
        defer { blitter.stop() }

        let tests = try #require(Bundle.allBundles.first { $0.bundlePath.hasSuffix("BlitterCoreTests.xctest") })
        let process = Process()
        process
            .executableURL = URL(fileURLWithPath: (tests.bundlePath as NSString).deletingLastPathComponent + "/blitter")
        process.arguments = ["mcp"]
        process.environment = ["BLITTER_SOCKET": socket]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        let lines = [
            message("initialize", ["protocolVersion": "2025-06-18"]),
            message("notifications/initialized", id: nil),
            message("tools/call", id: 2, ["name": "state", "arguments": [:]]),
        ]
        input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close() // stdin ends: the server ends
        process.waitUntilExit()
        let replies = (String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .split(separator: "\n").map(String.init)
        #expect(process.terminationStatus == 0 && replies.count == 2) // nothing for the notification
        let state = try decode(replies.last)
        #expect(state["id"] == 2 && state["result"]?["isError"] == false)
        #expect(state["result"]?["content"]?.array?.first?["text"]?.string?.contains("right") == true)
    }

    @Test func envelopesAreCheckedResponsesIgnored() throws {
        let server = MCPServer { _, _ in ["result": [:]] }
        func code(_ line: String) throws -> Int? {
            try decode(server.handle(line))["error"]?["code"]?.int
        }
        #expect(try code(#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#) == -32600)
        #expect(try code(#"{"jsonrpc":"2.0","id":true,"method":"ping"}"#) == -32600)
        #expect(try decode(server.handle(#"{"jsonrpc":"2.0","id":true,"method":"ping"}"#))["id"] == .null)
        #expect(try code(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#) == -32600)
        #expect(try code(#"{"jsonrpc":"2.0","id":1,"method":42}"#) == -32600)
        #expect(try code(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#) == -32600)
        #expect(try code(#"{"jsonrpc":"2.0","id":5}"#) == -32600)
        #expect(server.handle(#"{"jsonrpc":"2.0","id":5,"result":{}}"#) == nil) // a response to us
        #expect(server.handle(#"{"jsonrpc":"2.0","method":42}"#) != nil) // invalid, even without id
        #expect(try decode(server.handle(#"{"jsonrpc":"2.0","id":"a","method":"ping"}"#))["result"] == [:])
    }

    /// Arguments that do not fit a tool's schema are refused before Blitter is asked.
    @Test func argumentsAreCheckedAgainstTheSchema() throws {
        var reached = 0
        let server = MCPServer { _, _ in
            reached += 1
            return ["result": [:]]
        }
        let wrong: [(String, JSONValue)] = [
            ("select", ["side": 123, "names": []]), ("select", ["side": "up", "names": []]),
            ("select", ["side": "left", "names": [1]]), ("select", ["side": "left"]),
            ("navigate", ["side": "left"]), ("navigate", ["side": "left", "path": "/", "force": true]),
            ("listing", ["limit": 0]), ("listing", ["limit": 6000]), ("listing", ["offset": -1]),
            ("listing", ["offset": .number(1.5)]), ("run", [:]), ("run", ["action": 7]), ("state", [1]),
        ]
        for (name, arguments) in wrong {
            let reply = try decode(server.handle(message(
                "tools/call",
                ["name": .string(name), "arguments": arguments]
            )))
            #expect(reply["error"]?["code"] == -32602, "\(name) \(arguments.line)")
        }
        #expect(reached == 0)
        let fine = try decode(server.handle(message("tools/call", ["name": "listing",
                                                                   "arguments": ["side": "left", "limit": 5]])))
        #expect(fine["result"]?["isError"] == false && reached == 1)
    }

    /// A run whose answer never came is reported, never sent again; one that never reached the
    /// old connection goes to the new one, once (#60 review).
    @Test func theSessionNeverRepeatsWhatMayHaveRun() async throws {
        let folder = NSTemporaryDirectory() + "bn-" + String(UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let socket = folder + "/s.sock"
        let runs = RunCounter()
        func blitter(holdingRuns: Bool) -> LineSocketServer {
            LineSocketServer(path: socket) { line, _ in
                let request = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
                if request?["method"] == "run" {
                    runs.add()
                    while holdingRuns, !Task.isCancelled { // its answer never comes
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
                return JSONValue.object(["jsonrpc": "2.0", "id": request?["id"] ?? .null, "result": "ok"]).line
            }
        }
        let first = blitter(holdingRuns: true)
        try first.start()
        let session = AutomationSession { try AutomationClient(path: socket) }
        #expect(try session.call("state", [:])["result"] == "ok") // the connection is open
        let box = SessionBox(session) // used on one thread at a time
        let running = Task.detached { () -> AutomationClient.Failure? in
            do {
                _ = try box.session.call("run", ["action": "move-to-trash"])
                return nil
            } catch {
                return error as? AutomationClient.Failure
            }
        }
        for _ in 0 ..< 300 where runs.value == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        first.stop() // Blitter goes away while the run waits
        #expect(await running.value == .closed)
        #expect(runs.value == 1)

        let second = blitter(holdingRuns: false)
        try second.start()
        #expect(try session.call("state", [:])["result"] == "ok") // a new connection
        second.stop()
        let third = blitter(holdingRuns: false)
        try third.start() // Blitter restarted while the session was idle
        defer { third.stop() }
        #expect(try session.call("run", ["action": "new-folder"])["result"] == "ok")
        #expect(runs.value == 2) // the first run once, this one once
    }
}

final class RunCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func add() {
        lock.withLock { count += 1 }
    }
}

final class SessionBox: @unchecked Sendable {
    let session: AutomationSession

    init(_ session: AutomationSession) {
        self.session = session
    }
}
