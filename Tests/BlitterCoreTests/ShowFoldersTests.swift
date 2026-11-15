@testable import BlitterCore
import Foundation
import Synchronization
import Testing

/// What the recording server saw, and what it answers by method (ShowFoldersTests).
private final class RecorderLog: Sendable {
    let seen = Mutex<[String]>([])
    let answers = Mutex<[String: JSONValue]>(["navigate": ["status": "loaded"], "select": ["notListed": []]])
}

/// #98: `blitter [--new] [PATH [PATH]]` from a terminal: what is parsed, which requests it makes,
/// and the built tool doing it against a server that records them.
@Suite(.serialized)
struct ShowFoldersTests {
    private struct ToolResult {
        let status: Int32
        let output: String
        let errors: String
    }

    private let disk: [String: ShowFolders.Kind] = [
        "/work": .folder, "/work/a": .folder, "/work/b": .folder, "/work/notes.txt": .item,
        "/work/Blitter.app": .item, "/Users/me": .folder, "/Users/me/x": .folder, "/work/state": .folder,
    ]

    private func parse(_ words: String) throws -> ShowFolders? {
        try ShowFolders.parse(words.split(separator: " ").map(String.init), in: "/work", home: "/Users/me") {
            disk[$0] ?? .missing
        }
    }

    private func requests(_ words: String) throws -> [String] {
        let show = try parse(words)
        return try #require(show).requests.map { $0.method + " " + $0.params.line }
    }

    @Test func pathsAreTheTerminalsAndCommandsStayCommands() throws {
        #expect(try parse(".") == ShowFolders(newWindow: false, targets: [.init(folder: "/work", selecting: nil)]))
        #expect(try parse("a ../work/b")?.targets.map(\.folder) == ["/work/a", "/work/b"])
        #expect(try parse("~ ~/x")?.targets.map(\.folder) == ["/Users/me", "/Users/me/x"])
        #expect(try parse("notes.txt")?.targets == [.init(folder: "/work", selecting: "notes.txt")])
        #expect(try parse("Blitter.app")?.targets == [.init(folder: "/work", selecting: "Blitter.app")]) // a package
        #expect(try parse("--new") == ShowFolders(newWindow: true, targets: []))
        for command in ["state", "run x", "help", "--help", "-h", "mcp", "listing left"] {
            #expect(try parse(command) == nil, "\(command)") // the tool's commands
        }
        #expect(try parse("./state")?.targets.map(\.folder) == ["/work/state"])
        #expect(try ShowFolders.parse([], in: "/work", home: "/Users/me") { _ in .folder } == nil) // the usage
        for wrong in ["missing", "a b a", "--new --newer", "a -x"] {
            #expect(throws: AutomationCommandLine.Usage.self, "\(wrong)") { try parse(wrong) }
        }
    }

    @Test func eachSyntaxMakesItsRequests() throws {
        #expect(try requests(".") == [#"navigate {"path":"/work"}"#]) // the active side
        #expect(try requests("a b") == [#"navigate {"path":"/work/a","side":"left"}"#,
                                        #"navigate {"path":"/work/b","side":"right"}"#])
        #expect(try requests("notes.txt") == [#"navigate {"path":"/work"}"#,
                                              #"select {"names":["notes.txt"],"reveal":true}"#])
        #expect(try requests("--new") == [#"run {"action":"new-window"}"#])
        #expect(try requests("--new a") == [#"run {"action":"new-window"}"#,
                                            #"navigate {"path":"/work/a","side":"left"}"#,
                                            #"navigate {"path":"/work/a","side":"right"}"#])
        #expect(try requests("--new a b").count == 3)
    }

    /// A folder with sub/notes.txt, and a socket server in it that records each request and
    /// answers like Blitter: a folder read, everything selected — unless `answers` says otherwise.
    private final class Recorder: Sendable {
        static let fine: [String: JSONValue] = ["navigate": ["status": "loaded"], "select": ["notListed": []]]
        let folder = NSTemporaryDirectory() + "bf-" + String(UUID().uuidString.prefix(8))
        let real: String
        let log = RecorderLog()
        let server: LineSocketServer

        var socket: String {
            folder + "/s.sock"
        }

        init() throws {
            try FileManager.default.createDirectory(atPath: folder + "/sub", withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: folder + "/sub/notes.txt", contents: Data())
            real = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path // /var → /private/var
            let log = log
            server = LineSocketServer(path: folder + "/s.sock") { line, _ in
                let request = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
                let method = request?["method"]?.string ?? ""
                log.seen.withLock { $0.append(method + " " + (request?["params"]?.line ?? "")) }
                let result = log.answers.withLock { $0[method] } ?? [:]
                return JSONValue.object(["jsonrpc": "2.0", "id": request?["id"] ?? .null, "result": result]).line
            }
            try server.start()
        }

        deinit {
            server.stop()
            try? FileManager.default.removeItem(atPath: folder)
        }
    }

    @Test func theBuiltToolShowsFoldersAndPrintsNothing() throws {
        let recorder = try Recorder()
        let result = try runTool(["--new", "sub/notes.txt", "."], in: recorder.real, socket: recorder.socket)
        #expect(result.status == 0 && result.output.isEmpty)
        #expect(recorder.log.seen.withLock { $0 } == [
            #"run {"action":"new-window"}"#,
            #"navigate {"path":"\#(recorder.real)/sub","side":"left"}"#,
            #"select {"names":["notes.txt"],"reveal":true,"side":"left"}"#,
            #"navigate {"path":"\#(recorder.real)","side":"right"}"#,
        ])
        let missing = try runTool(["nowhere"], in: recorder.real, socket: recorder.socket)
        #expect(missing.status == 1 && missing.errors.contains("“nowhere”: no such file or folder"))
        let help = try runTool(["--help"], in: recorder.real, socket: recorder.socket)
        #expect(help.status == 0 && help.output.contains("blitter [--new] [FOLDER [FOLDER]]"))
        recorder.server.stop()
        let notRunning = try runTool(["."], in: recorder.real, socket: recorder.socket)
        #expect(notRunning.status == 2 && notRunning.errors.contains("Blitter is not running"))
    }

    /// #98 review: a folder not read, or still being read, or an item not there to select stops
    /// the tool with the reason, and nothing more is sent.
    @Test func whatDidNotWorkStopsTheTool() throws {
        let recorder = try Recorder()
        struct Failure {
            let method: String
            let answer: JSONValue
            let message: String
            let requests: Int
        }
        let failures = [
            Failure(method: "navigate", answer: ["status": "failed", "error": "No permission."],
                    message: "\(recorder.real)/sub: No permission.", requests: 1),
            Failure(method: "navigate", answer: ["status": "loading"], message: "is still being read", requests: 1),
            Failure(method: "select", answer: ["notListed": ["notes.txt"]],
                    message: "“notes.txt” is not there to select.", requests: 2),
        ]
        for failure in failures {
            recorder.log.answers.withLock { $0 = Recorder.fine; $0[failure.method] = failure.answer }
            recorder.log.seen.withLock { $0 = [] }
            let stopped = try runTool(["sub/notes.txt", "."], in: recorder.real, socket: recorder.socket)
            #expect(stopped.status == 1 && stopped.errors.contains(failure.message), "\(stopped.errors)")
            #expect(recorder.log.seen.withLock { $0.count } == failure.requests) // nothing more was sent
        }
    }

    private func runTool(_ arguments: [String], in folder: String,
                         socket: String) throws -> ToolResult
    {
        let tests = try #require(Bundle.allBundles.first { $0.bundlePath.hasSuffix("BlitterCoreTests.xctest") })
        let process = Process()
        process
            .executableURL = URL(fileURLWithPath: (tests.bundlePath as NSString).deletingLastPathComponent + "/blitter")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.environment = ["BLITTER_SOCKET": socket, "HOME": NSHomeDirectory()]
        let (output, errors) = (Pipe(), Pipe())
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        func text(_ pipe: Pipe) -> String {
            String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        return ToolResult(status: process.terminationStatus, output: text(output), errors: text(errors))
    }
}
