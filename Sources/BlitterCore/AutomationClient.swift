import Foundation

/// The client side of the automation socket (#58, #59): what the `blitter` tool, its MCP server
/// and tests use to talk to a running Blitter. One connection; requests are answered in order.
public final class AutomationClient {
    public enum Failure: Error, Equatable {
        /// Nothing serves at the path: Blitter is not running (or has automation off).
        case notRunning(String)
        /// The connection was gone before the request was sent: Blitter never got it.
        case notSent
        /// The connection ended after the request was sent, before its answer: whether Blitter
        /// carried it out is not known.
        case closed
        case system(String, Int32)
    }

    private let socket: Int32
    private var pending = Data()
    private var nextID = 1

    /// The socket a client uses: `BLITTER_SOCKET` if set (tests, a second instance), else the
    /// user's.
    public static var defaultPath: String {
        ProcessInfo.processInfo.environment["BLITTER_SOCKET"] ?? UserPaths.automationSocket
    }

    /// The descriptor is kept only once connected: until then it is a local one, closed exactly
    /// once on every failure (an instance that throws after it is complete would close it again
    /// in `deinit`, #59 review).
    public init(path: String = AutomationClient.defaultPath) throws {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw Failure.system("socket", errno)
        }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        do {
            var address = try LineSocketServer.address(path)
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else {
                let code = errno
                throw code == ENOENT || code == ECONNREFUSED ? Failure.notRunning(path)
                    : Failure.system("connect", code)
            }
        } catch {
            close(descriptor)
            throw error
        }
        socket = descriptor
    }

    deinit {
        close(socket)
    }

    /// Sends a request and waits for its answer, which may take as long as the user takes to
    /// allow a change. Returns the reply object (`result` or `error`).
    public func call(_ method: String, _ params: JSONValue = [:]) throws -> JSONValue {
        let id = nextID
        nextID += 1
        let request: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method),
                                  "params": params]
        try send(request.line + "\n")
        while true {
            let line = try readLine()
            if let reply = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)), reply["id"]?.int == id {
                return reply
            }
        }
    }

    private func send(_ text: String) throws {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
            guard written > 0 else {
                // Nothing of a line Blitter has not seen whole counts: it answers lines only.
                throw Failure.notSent
            }
            bytes = bytes.dropFirst(written)
        }
    }

    private func readLine() throws -> String {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex ..< newline]
                pending.removeSubrange(pending.startIndex ... newline)
                return String(bytes: line, encoding: .utf8) ?? ""
            }
            let count = buffer.withUnsafeMutableBytes { read(socket, $0.baseAddress, $0.count) }
            guard count > 0 else {
                throw Failure.closed
            }
            pending.append(contentsOf: buffer[0 ..< count])
        }
    }
}

/// The `blitter` tool's command line (#59): which request each command makes. Kept here, apart
/// from the tool's `main`, so it is tested.
public enum AutomationCommandLine {
    public struct Usage: Error, Equatable {
        public let message: String
    }

    public static let help = """
    usage: blitter <command> [arguments]   (Blitter must be running)
      state                          both sides: folders, selections, sort, active side
      listing [SIDE] [--offset N] [--limit N]
                                     a side's items, as the list shows them
      actions [SIDE]                 the actions offered, and whether each fits now
      navigate SIDE PATH             go to a folder; answers once it is read
      select SIDE NAME...            select exactly these items (none: clear)
      activate SIDE                  make SIDE the active side
      preview ACTION [SIDE]          what an action would do now; nothing happens
      run ACTION [SIDE]              run it; changes wait for Allow in Blitter
      call METHOD [JSON]             any request, with params as a JSON object
      mcp                            an MCP server on stdin/stdout, for Claude Code or Codex
    SIDE is left or right (the active side if left out). The socket is
    BLITTER_SOCKET, or ~/Library/Application Support/Blitter/automation.sock.
    """

    /// The method and params for a command line (without the program's name).
    public static func request(_ arguments: [String]) throws(Usage) -> (method: String, params: JSONValue) {
        guard let command = arguments.first else {
            throw Usage(message: help)
        }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "state", "hello":
            try expect(rest, count: 0 ... 0)
            return (command, [:])
        case "listing": return try listing(rest)
        case "actions":
            try expect(rest, count: 0 ... 1)
            return try ("actions", sided([:], rest.first))
        case "navigate":
            try expect(rest, count: 2 ... 2)
            return try ("navigate", sided(["path": .string(rest[1])], rest[0]))
        case "select":
            try expect(rest, count: 1 ... Int.max)
            return try ("select", sided(["names": .array(rest.dropFirst().map(JSONValue.string))], rest[0]))
        case "activate":
            try expect(rest, count: 1 ... 1)
            return try ("activate", sided([:], rest[0]))
        case "preview", "run":
            try expect(rest, count: 1 ... 2)
            return try (command, sided(["action": .string(rest[0])], rest.count > 1 ? rest[1] : nil))
        case "call": return try call(rest)
        case "help", "-h", "--help": throw Usage(message: help)
        default: throw Usage(message: "blitter: unknown command “\(command)”.\n" + help)
        }
    }

    private static func listing(_ rest: [String]) throws(Usage) -> (method: String, params: JSONValue) {
        var params: [String: JSONValue] = [:]
        var side: String?
        var index = 0
        while index < rest.count {
            let word = rest[index]
            if word == "--offset" || word == "--limit" {
                guard index + 1 < rest.count, let number = Int(rest[index + 1]), number >= 0 else {
                    throw Usage(message: "blitter: \(word) needs a number.")
                }
                params[String(word.dropFirst(2))] = .number(Double(number))
                index += 2
            } else if side == nil {
                side = word
                index += 1
            } else {
                throw Usage(message: "blitter: listing takes one side.")
            }
        }
        return try ("listing", sided(.object(params), side))
    }

    private static func call(_ rest: [String]) throws(Usage) -> (method: String, params: JSONValue) {
        try expect(rest, count: 1 ... 2)
        guard rest.count == 2 else {
            return (rest[0], [:])
        }
        guard let params = try? JSONDecoder().decode(JSONValue.self, from: Data(rest[1].utf8)),
              case .object = params
        else {
            throw Usage(message: "blitter: the params must be a JSON object, e.g. '{\"side\": \"left\"}'.")
        }
        return (rest[0], params)
    }

    private static func sided(_ params: JSONValue, _ side: String?) throws(Usage) -> JSONValue {
        guard let side else {
            return params
        }
        guard side == "left" || side == "right", case var .object(object) = params else {
            throw Usage(message: "blitter: SIDE is left or right, not “\(side)”.")
        }
        object["side"] = .string(side)
        return .object(object)
    }

    private static func expect(_ rest: [String], count: ClosedRange<Int>) throws(Usage) {
        guard count.contains(rest.count) else {
            throw Usage(message: "blitter: wrong number of arguments.\n" + help)
        }
    }
}
