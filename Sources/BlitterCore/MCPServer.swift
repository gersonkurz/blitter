import Foundation

/// `blitter mcp` (#60): the Model Context Protocol over stdio, one JSON-RPC message per line, with
/// Blitter's automation socket behind it. Each tool is one socket method; what changes files or
/// opens something still waits for the user's Allow in Blitter. This type only translates:
/// a line in, a line out (or none, for a notification); `call` reaches Blitter.
public struct MCPServer {
    /// Sends a request to Blitter and returns its reply object (`result` or `error`).
    public typealias Caller = (_ method: String, _ params: JSONValue) throws -> JSONValue

    private let call: Caller

    public init(call: @escaping Caller) {
        self.call = call
    }

    /// The protocol versions understood; the client's is taken if it is one of them.
    static let versions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    /// Answers one message, or nil for a notification or a response. Envelopes are checked
    /// as JSON-RPC 2.0 has them: an object, version "2.0", a string method, an id that is a
    /// string or a number (#60 review). Batches are not part of MCP.
    public func handle(_ line: String) -> String? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else {
            return Self.error(id: .null, code: -32700, "The message is not JSON.")
        }
        guard case let .object(envelope) = message else {
            return Self.error(id: .null, code: -32600, "A message must be one JSON object.")
        }
        let id = envelope["id"]
        let validID = switch id {
        case .string?, .number?: true
        default: false
        }
        guard let method = envelope["method"] else {
            let isResponse = validID && (envelope["result"] != nil || envelope["error"] != nil)
            return isResponse ? nil : Self.error(id: validID ? id ?? .null : .null, code: -32600,
                                                 "A request needs a method.")
        }
        guard envelope["jsonrpc"] == "2.0", case let .string(name) = method, id == nil || validID else {
            return Self.error(id: validID ? id ?? .null : .null, code: -32600,
                              "Not a JSON-RPC 2.0 request: version \"2.0\", a string method, a string or number id.")
        }
        guard let id else {
            return nil // a notification (initialized, cancelled): nothing to answer
        }
        return answer(name, id: id, params: envelope["params"] ?? [:])
    }

    private func answer(_ method: String, id: JSONValue, params: JSONValue) -> String {
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.string ?? ""
            return Self.result(id: id, [
                "protocolVersion": .string(Self.versions.contains(asked) ? asked : Self.versions[0]),
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "blitter", "version": "1"],
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": .array(Self.tools.map(\.json))])
        case "tools/call":
            return toolCall(id: id, params)
        default:
            return Self.error(id: id, code: -32601, "There is no method “\(method)”.")
        }
    }

    private func toolCall(id: JSONValue, _ params: JSONValue) -> String {
        guard let name = params["name"]?.string, let tool = Self.tools.first(where: { $0.name == name }) else {
            return Self.error(id: id, code: -32602, "There is no tool “\(params["name"]?.string ?? "")”.")
        }
        let arguments = params["arguments"] ?? [:]
        if let problem = tool.problem(with: arguments) {
            return Self.error(id: id, code: -32602, "\(name): \(problem)") // Blitter is not asked
        }
        let text: String
        let failed: Bool
        do {
            let reply = try call(tool.name, arguments)
            if let error = reply["error"] {
                (text, failed) = ("\(error["message"]?.string ?? "Error") (code \(error["code"]?.int ?? 0))", true)
            } else {
                (text, failed) = (Self.pretty(reply["result"] ?? .null), false)
            }
        } catch AutomationClient.Failure.notRunning {
            (text, failed) = ("Blitter is not running. Start it, then try again.", true)
        } catch AutomationClient.Failure.closed {
            (text, failed) = ("The connection to Blitter ended before it answered: “\(name)” may or may not have "
                + "run. Look at the state before trying again.", true)
        } catch {
            (text, failed) = ("Blitter could not be reached: \(error)", true)
        }
        return Self.result(id: id, ["content": [["type": "text", "text": .string(text)]], "isError": .bool(failed)])
    }

    private static func result(id: JSONValue, _ result: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).line
    }

    private static func error(id: JSONValue, code: Int, _ message: String) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id,
                          "error": ["code": .number(Double(code)), "message": .string(message)]]).line
    }

    private static func pretty(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(bytes: $0, encoding: .utf8) } ?? value.line
    }
}

// MARK: Tools

extension MCPServer {
    static let instructions = """
    Blitter is a two-sided file manager on this Mac. Read its state and listings freely. To act, \
    select items on a side, then run an action on that side. Ask for a preview first: run \
    shows the user the same preview in Blitter and waits for them to allow it; they may deny it. \
    Deletes go to the Trash; deleting for good, the clipboard and renaming are not offered.
    """

    struct Tool {
        let name: String
        let description: String
        let properties: [String: JSONValue]
        let required: [String]

        /// What is wrong with the arguments, checked against the schema the tool advertises
        /// (an object; known names only; the required ones; strings, enums, whole numbers within
        /// bounds, lists of strings), or nil (#60 review).
        func problem(with arguments: JSONValue) -> String? {
            guard case let .object(given) = arguments else {
                return "the arguments must be an object."
            }
            if let unknown = given.keys.sorted().first(where: { properties[$0] == nil }) {
                return "there is no argument “\(unknown)”."
            }
            if let missing = required.first(where: { given[$0] == nil }) {
                return "“\(missing)” is needed."
            }
            for (key, value) in given.sorted(by: { $0.key < $1.key }) {
                if let schema = properties[key], let problem = Self.problem(value, schema) {
                    return "“\(key)” \(problem)"
                }
            }
            return nil
        }

        private static func problem(_ value: JSONValue, _ schema: JSONValue) -> String? {
            switch schema["type"]?.string {
            case "string":
                guard let text = value.string else {
                    return "must be a string."
                }
                if let allowed = schema["enum"]?.array, !allowed.contains(.string(text)) {
                    return "must be one of " + allowed.compactMap(\.string).joined(separator: ", ") + "."
                }
            case "integer":
                guard let number = value.int else {
                    return "must be a whole number."
                }
                if let low = schema["minimum"]?.int, number < low {
                    return "must be at least \(low)."
                }
                if let high = schema["maximum"]?.int, number > high {
                    return "must be at most \(high)."
                }
            case "array":
                guard let items = value.array, items.allSatisfy({ $0.string != nil }) else {
                    return "must be a list of strings."
                }
            default:
                break
            }
            return nil
        }

        var json: JSONValue {
            ["name": .string(name), "description": .string(description),
             "inputSchema": ["type": "object", "properties": .object(properties),
                             "required": .array(required.map(JSONValue.string)), "additionalProperties": false]]
        }
    }

    private static let side: JSONValue = [
        "type": "string", "enum": ["left", "right"], "description": "The side; the active one if left out.",
    ]
    private static let action: JSONValue = ["type": "string", "description": "An action id from `actions`."]

    /// Each tool is the socket method of the same name, its arguments the method's params.
    static let tools = [
        Tool(name: "state", description: "Both sides: folder, status, selected names, sort, the active side.",
             properties: [:], required: []),
        Tool(name: "listing", description: "A side's items as its list shows them (name, kind, size, modified), paged.",
             properties: ["side": side, "offset": ["type": "integer", "minimum": 0],
                          "limit": ["type": "integer", "minimum": 1, "maximum": 5000]], required: []),
        Tool(name: "actions",
             description: "The actions offered, with their effect (view, opens, changes) and whether each fits now.",
             properties: ["side": side], required: []),
        Tool(name: "navigate", description: "Show a folder on a side; answers once it is read.",
             properties: ["side": side, "path": ["type": "string", "description": "An absolute path or ~/…"]],
             required: ["side", "path"]),
        Tool(name: "select", description: "Select exactly these items (names from `listing`) on a side.",
             properties: ["side": side, "names": ["type": "array", "items": ["type": "string"]]],
             required: ["side", "names"]),
        Tool(name: "activate", description: "Make a side the active one.", properties: ["side": side],
             required: ["side"]),
        Tool(name: "preview", description: "What an action would do on a side now: its items and destination. "
            + "Nothing happens.", properties: ["action": action, "side": side], required: ["action"]),
        Tool(name: "run", description: "Run an action on a side. One that changes files or opens something waits "
            + "until the user allows it in Blitter, and runs only if it still does what the preview showed.",
            properties: ["action": action, "side": side], required: ["action"]),
    ]
}
