import AppKit
@testable import Blitter
@testable import BlitterCore
@testable import BlitterModel
import Testing

/// The sheet that asks before an automation client's change runs (#58), in the main window.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
final class AutomationPromptTests {
    private let folder: String

    init() throws {
        folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
            + "/BlitterAutomation-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder + "/target", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder + "/a.txt", contents: Data("a".utf8))
    }

    deinit {
        try? FileManager.default.removeItem(atPath: folder)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    private func request(_ method: String, _ params: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": 1, "method": .string(method), "params": params]).line
    }

    @Test func theSheetAsksAllowRunsAGoneClientClosesIt() async throws {
        let workspace = Workspace(initialLocation: folder, home: folder, volumes: { [] }, watcher: FakeWatcher.factory)
        let controller = MainWindowController(workspace: workspace)
        let window = try #require(controller.window)
        controller.showWindow(nil)
        defer { window.close() }
        try await waitUntil { workspace.state(of: .left).visibleEntries.count == 2 }
        workspace.perform(.navigate(.right, path: folder + "/target"))
        try await waitUntil { workspace.state(of: .right).entriesLocation == self.folder + "/target" }
        workspace.perform(.select(.left, ["a.txt"]))
        let copy = request("run", ["action": "copy-to-other-side", "side": "left"])

        let running = Task { await workspace.handleAutomation(copy, client: "blitter (pid 42)") }
        try await waitUntil { window.attachedSheet != nil }
        let alert = try #require(controller.automationPrompt.shown?.alert)
        #expect(alert.messageText == "blitter (pid 42) wants to run “Copy to Other Side”")
        #expect(alert.informativeText == folder + "/a.txt\nin “\(folder)/target”")
        #expect(alert.buttons.map(\.title) == ["Deny", "Allow"])
        window.endSheet(alert.window, returnCode: AutomationPrompt.allow)
        let reply = try #require(await running.value)
        #expect(reply.contains("\"done\":true") && reply.contains("\"state\":\"finished\""))
        #expect(FileManager.default.fileExists(atPath: folder + "/target/a.txt"))

        // A client that goes away: its question closes.
        let gone = Task { await workspace.handleAutomation(copy, client: "blitter (pid 43)") }
        try await waitUntil { window.attachedSheet != nil }
        gone.cancel()
        _ = await gone.value
        try await waitUntil { window.attachedSheet == nil }
        #expect(workspace.automationConfirmation == nil)
    }

    /// End to end: the app's handler on a real socket, as `startAutomation` wires it.
    @Test func aRealSocketReachesTheWorkspace() async throws {
        let workspace = Workspace(initialLocation: folder, home: folder, volumes: { [] }, watcher: FakeWatcher.factory)
        try await waitUntil { workspace.state(of: .left).visibleEntries.count == 2 }
        let path = NSTemporaryDirectory() + "ba-" + String(UUID().uuidString.prefix(8)) + "/s.sock"
        let server = LineSocketServer(path: path) { line, client in
            await workspace.handleAutomation(line, client: "\(client.name) (pid \(client.pid))")
        }
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
        }
        let line = request("state", [:])
        let reply = try await Task.detached { try Self.exchange(path, line) }.value
        let state = try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))
        #expect(state["result"]?["sides"]?["left"]?["location"]?.string == folder)
    }

    /// One request, one reply, over a fresh connection (off the main actor: the server answers there).
    private nonisolated static func exchange(_ path: String, _ line: String) throws -> String {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = try LineSocketServer.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(connected == 0)
        _ = Array((line + "\n").utf8).withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
        var reply = Data()
        var byte: UInt8 = 0
        while read(socket, &byte, 1) == 1, byte != 0x0A {
            reply.append(byte)
        }
        return String(bytes: reply, encoding: .utf8) ?? ""
    }
}
