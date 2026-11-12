@testable import BlitterCore
import Foundation
import Synchronization
import Testing

/// A client for the tests: connects, sends lines, reads lines.
final class SocketTestClient {
    let socket: Int32
    private var pending = Data()

    init(_ path: String) throws {
        socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try LineSocketServer.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(socket)
            throw POSIXError(.ECONNREFUSED)
        }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit {
        close(socket)
    }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
    }

    /// The next line, or nil when the server closed the connection (or 5 seconds passed).
    func readLine() -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = String(bytes: pending[pending.startIndex ..< newline], encoding: .utf8) ?? ""
                pending.removeSubrange(pending.startIndex ... newline)
                return line
            }
            let count = buffer.withUnsafeMutableBytes { read(socket, $0.baseAddress, $0.count) }
            guard count > 0 else {
                return nil
            }
            pending.append(contentsOf: buffer[0 ..< count])
        }
    }
}

/// The automation socket's transport (#58), on real sockets.
@Suite(.serialized)
struct LineSocketServerTests {
    /// Short: a socket path may have at most 103 bytes.
    private let folder = NSTemporaryDirectory() + "bs-" + String(UUID().uuidString.prefix(8))
    private var path: String {
        folder + "/s.sock"
    }

    @Test func linesAreAnsweredInOrderOnlyForThisUser() throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = LineSocketServer(path: path) { line, client in
            "\(line.uppercased()) from \(client.pid == getpid() ? "me" : "someone")"
        }
        try server.start()
        defer { server.stop() }
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? Int
        let socketMode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(folderMode == 0o700 && socketMode == 0o600)

        let client = try SocketTestClient(path)
        client.send("one\n\ntwo\nthr") // an empty line is skipped; a line comes in pieces
        client.send("ee\n")
        #expect(client.readLine() == "ONE from me")
        #expect(client.readLine() == "TWO from me")
        #expect(client.readLine() == "THREE from me")
        let other = try SocketTestClient(path) // several clients at once
        other.send("four\n")
        #expect(other.readLine() == "FOUR from me")
    }

    @Test func aSecondServerLeavesTheSocketALeftoverIsReplaced() throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let first = LineSocketServer(path: path) { line, _ in line }
        try first.start()
        #expect(throws: LineSocketServer.Failure.inUse) {
            try LineSocketServer(path: path) { line, _ in line }.start()
        }
        first.stop()
        #expect(!FileManager.default.fileExists(atPath: path)) // stopping removes it

        // A socket file nobody serves (a Blitter that crashed): the next one takes the path.
        let leftover = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try LineSocketServer.address(path)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(leftover, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(leftover)
        #expect(FileManager.default.fileExists(atPath: path))
        let next = LineSocketServer(path: path) { line, _ in "next " + line }
        try next.start()
        defer { next.stop() }
        let client = try SocketTestClient(path)
        client.send("hi\n")
        #expect(client.readLine() == "next hi")
    }

    @Test func aClientThatGoesAwayCancelsItsRequestStoppingEndsTheRest() async throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let cancelled = CancellationFlag() // set once the handler saw the cancellation
        let server = LineSocketServer(path: path) { line, _ in
            if line == "slow" {
                try? await Task.sleep(for: .milliseconds(600)) // longer than a few hang-up checks
                return "slow done"
            }
            guard line == "wait" else {
                return line
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            cancelled.set()
            return "cancelled"
        }
        try server.start()
        defer { server.stop() }
        var client: SocketTestClient? = try SocketTestClient(path)
        client?.send("wait\n")
        try await Task.sleep(for: .milliseconds(100))
        client = nil // hangs up
        for _ in 0 ..< 200 where !cancelled.isSet {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(cancelled.isSet)

        // A client that is only done sending still gets its answer.
        let sender = try SocketTestClient(path)
        sender.send("slow\n")
        shutdown(sender.socket, SHUT_WR)
        #expect(sender.readLine() == "slow done")

        let staying = try SocketTestClient(path)
        staying.send("still\n")
        #expect(staying.readLine() == "still")
        server.stop()
        #expect(staying.readLine() == nil) // the connection ends
    }

    /// Two Blitters starting at the same moment: exactly one serves (#58 review).
    @Test func twoServersStartingTogetherOneWins() throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let servers = (0 ..< 4).map { index in LineSocketServer(path: path) { _, _ in "server \(index)" } }
        let results = Mutex([Bool](repeating: false, count: servers.count))
        DispatchQueue.concurrentPerform(iterations: servers.count) { index in
            let started = (try? servers[index].start()) != nil
            results.withLock { $0[index] = started }
        }
        let started = results.withLock { $0 }
        #expect(started.count(where: \.self) == 1)
        let winner = try #require(started.firstIndex(of: true))
        let client = try SocketTestClient(path)
        client.send("who\n")
        #expect(client.readLine() == "server \(winner)")
        servers[winner].stop()
        let next = LineSocketServer(path: path) { _, _ in "next" }
        try next.start() // the lock went with the winner
        next.stop()
    }

    @Test func whatIsNotASocketIsLeftAloneAPermissiveFolderIsMadePrivate() throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o777])
        FileManager.default.createFile(atPath: path, contents: Data("mine".utf8))
        #expect(throws: LineSocketServer.Failure.notASocket) {
            try LineSocketServer(path: path) { line, _ in line }.start()
        }
        #expect(FileManager.default.contents(atPath: path) == Data("mine".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? Int
        #expect(mode == 0o700) // nobody else can replace the socket in it
        try FileManager.default.removeItem(atPath: path)
        let server = LineSocketServer(path: path) { line, _ in line }
        try server.start() // the failed start let go of the lock
        server.stop()

        // A folder that is a link is not used.
        let linked = NSTemporaryDirectory() + "bl-" + String(UUID().uuidString.prefix(8))
        try FileManager.default.createSymbolicLink(atPath: linked, withDestinationPath: folder)
        defer { try? FileManager.default.removeItem(atPath: linked) }
        #expect(throws: LineSocketServer.Failure.unsafeFolder) {
            try LineSocketServer(path: linked + "/s.sock") { line, _ in line }.start()
        }
    }

    @Test func notificationsGetNoAnswerOverlongLinesEndTheConnection() throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = LineSocketServer(path: path, maximumLine: 10) { line, _ in line == "quiet" ? nil : "ok " + line }
        try server.start()
        defer { server.stop() }
        let client = try SocketTestClient(path)
        client.send("quiet\n1234567890\n") // no answer, then a line of exactly the limit
        #expect(client.readLine() == "ok 1234567890")
        client.send("12345")
        client.send("678901\n") // complete, but one byte too long
        #expect(client.readLine() == nil)
        let other = try SocketTestClient(path)
        other.send("123456789012") // too long before its newline even arrives
        #expect(other.readLine() == nil)
    }

    /// The app quits while the server is still starting (it starts off the main thread): nothing
    /// is left serving, no socket file, no held lock (#58 review).
    @Test func aStopBeforeOrDuringStartLeavesNothing() throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let early = LineSocketServer(path: path) { line, _ in line }
        early.stop()
        try early.start()
        #expect(!FileManager.default.fileExists(atPath: path))

        let during = LineSocketServer(path: path) { line, _ in line }
        during.beforePublishing = { during.stop() } // bound, not yet serving
        try during.start()
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(throws: (any Error).self) { try SocketTestClient(path) }

        let next = LineSocketServer(path: path) { line, _ in "next " + line }
        try next.start() // the lock was let go
        defer { next.stop() }
        let client = try SocketTestClient(path)
        client.send("hi\n")
        #expect(client.readLine() == "next hi")
    }

    /// #79: a server stopped right after it started leaves the next one's connections alone. Its
    /// accept thread, not yet waiting, used to accept on the descriptor `stop()` had closed —
    /// which the next server's socket had just been given — and closed what it took.
    @Test func aStoppedServersThreadNeverTakesTheNextOnesConnections() throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        var answered = 0
        for round in 0 ..< 200 {
            let stopped = LineSocketServer(path: path) { line, _ in line }
            try stopped.start()
            stopped.stop()
            let next = LineSocketServer(path: path) { line, _ in "next " + line }
            try next.start()
            let client = try SocketTestClient(path)
            client.send("\(round)\n")
            if client.readLine() == "next \(round)" {
                answered += 1
            }
            next.stop()
        }
        #expect(answered == 200)
    }

    /// #80: a path too long for a socket is refused without leaving a descriptor open, however
    /// often it is tried. (Other suites open descriptors meanwhile: a leak shows as ~1000 more.)
    @Test func aPathTooLongLeaksNothing() throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let long = folder + "/" + String(repeating: "x", count: 120) + ".sock"
        let before = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        for _ in 0 ..< 1000 {
            #expect(throws: LineSocketServer.Failure.system("path too long", ENAMETOOLONG)) {
                try LineSocketServer(path: long) { line, _ in line }.start()
            }
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        #expect(after - before < 100)
    }
}
