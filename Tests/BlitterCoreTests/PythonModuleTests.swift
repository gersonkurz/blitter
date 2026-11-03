@testable import BlitterCore
import Foundation
import Testing

/// The Python module (#28), run by the system's python3 against a test server.
@Suite(.serialized)
struct PythonModuleTests {
    /// The repository's python folder, found from this file.
    private static let module = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("python").path

    private static let python = "/usr/bin/python3"

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func theModuleTalksToBlitter() throws {
        let folder = NSTemporaryDirectory() + "bp-" + String(UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let socket = folder + "/s.sock"
        let server = Self.testServer(socket)
        try server.start()
        defer { server.stop() }
        let script = """
        import json, blitter
        with blitter.Blitter() as app:
            print(json.dumps(app.state(), sort_keys=True))
            print(json.dumps(app.select("left", ("a.txt", "b.txt")), sort_keys=True))
            print(json.dumps(app.listing("right", limit=5), sort_keys=True))
            print(",".join(e["name"] for e in app.all_entries("left", page=3)))
            try:
                app.run("move-to-trash", "left")
            except blitter.BlitterError as error:
                print("error", error.code, error.message)
        try:
            blitter.Blitter("\(folder)/none.sock")
        except blitter.NotRunning as error:
            print("not running", error.path)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.python)
        process.arguments = ["-I", "-B", "-c", "import sys; sys.path.insert(0, \(Self.quoted(Self.module)))\n" + script]
        process.environment = ["BLITTER_SOCKET": socket]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let lines = (String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .split(separator: "\n").map(String.init)
        #expect(process.terminationStatus == 0)
        #expect(lines == [
            #"{"method": "state", "params": {}}"#,
            #"{"method": "select", "params": {"names": ["a.txt", "b.txt"], "side": "left"}}"#,
            #"{"method": "listing", "params": {"limit": 5, "side": "right"}}"#, // None is left out
            "f0,f1,f2,f3,f4,f5,f6", // every page
            "error 3 Denied in Blitter.",
            "not running \(folder)/none.sock",
        ])
    }

    /// Answers like Blitter, for the module to talk to.
    private static func testServer(_ socket: String) -> LineSocketServer {
        // Answers with the method and params it got; "run" is denied, as a user would.
        LineSocketServer(path: socket) { line, _ in
            let request = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            let id = request?["id"] ?? .null
            if request?["method"] == "listing", let offset = request?["params"]?["offset"]?.int,
               let limit = request?["params"]?["limit"]?.int
            { // 7 items in all, in pages
                let names = (offset ..< min(offset + limit, 7)).map { JSONValue.object(["name": .string("f\($0)")]) }
                return JSONValue.object(["jsonrpc": "2.0", "id": id,
                                         "result": ["total": 7, "entries": .array(names)]]).line
            }
            guard request?["method"] != "run" else {
                return JSONValue.object(["jsonrpc": "2.0", "id": id,
                                         "error": ["code": 3, "message": "Denied in Blitter."]]).line
            }
            return JSONValue.object(["jsonrpc": "2.0", "id": id, "result": [
                "method": request?["method"] ?? .null, "params": request?["params"] ?? .null,
            ]]).line
        }
    }

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// A tool's command line gets the socket, so a script run as a tool reaches this Blitter.
    @MainActor
    @Test func aToolsCommandLineIsToldTheSocket() async throws {
        let fixture = try OperationFixture()
        let job = try await fixture.run(.command(["/usr/bin/printenv", "BLITTER_SOCKET"], folder: fixture.source))
        let printed = String(bytes: job.progress.outputBytes, encoding: .utf8) ?? ""
        #expect(printed.trimmingCharacters(in: .whitespacesAndNewlines) == UserPaths.automationSocket)
    }
}
