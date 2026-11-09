import BlitterCore
import Foundation

/// A failed automation request, as a JSON-RPC error (#58).
public struct AutomationError: Error, Equatable, Sendable {
    public let code: Int
    public let message: String

    static let parse = AutomationError(code: -32700, message: "The request is not JSON.")
    static let invalid = AutomationError(code: -32600,
                                         message: "Not a JSON-RPC 2.0 request (jsonrpc \"2.0\", a method, an id).")
    static func unknownMethod(_ name: String) -> AutomationError {
        AutomationError(code: -32601, message: "There is no method “\(name)”.")
    }

    static func invalidParams(_ text: String) -> AutomationError {
        AutomationError(code: -32602, message: text)
    }

    static func notOffered(_ id: String) -> AutomationError {
        AutomationError(code: 1, message: "“\(id)” is not offered over the automation socket.")
    }

    static func notRunnable(_ id: String) -> AutomationError {
        AutomationError(code: 2, message: "“\(id)” does not fit what the side shows or has selected now.")
    }

    static let denied = AutomationError(code: 3, message: "Denied in Blitter.")
    static let changed = AutomationError(code: 4, message: "The side changed while Blitter asked; preview again.")
    static let busy = AutomationError(code: 5, message: "Blitter is already asking about another change.")
}

// MARK: Requests

/// The automation socket's requests (#58): JSON-RPC 2.0, one request per line, answered with one
/// line. The methods are listed in docs/AUTOMATION.md. Whatever changes files or opens something
/// outside Blitter runs only once the user allows it in Blitter (`automationConfirmation`).
public extension Workspace {
    /// Answers one request line, or nil for a notification (a request without an id), which
    /// is carried out but not answered, as JSON-RPC 2.0 has it. `client` names the process
    /// asking, for the confirmation. Batches are not supported.
    func handleAutomation(_ line: String, client: String) async -> String? {
        guard let request = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else {
            return Self.reply(id: .null, error: .parse)
        }
        guard case let .object(envelope) = request else {
            return Self.reply(id: .null, error: .invalid) // a batch, or not a request at all
        }
        let id = envelope["id"]
        switch id {
        case nil, .string?, .number?, .null?: break
        default: return Self.reply(id: .null, error: .invalid)
        }
        guard envelope["jsonrpc"] == "2.0", let method = envelope["method"]?.string else {
            return Self.reply(id: id ?? .null, error: .invalid)
        }
        let params = envelope["params"] ?? [:]
        guard case .object = params else {
            return id.map { Self.reply(id: $0, error: .invalidParams("params must be an object.")) }
        }
        do {
            let result = try await call(method, params, client: client)
            return id.map { JSONValue.object(["jsonrpc": "2.0", "id": $0, "result": result]).line }
        } catch {
            return id.map { Self.reply(id: $0, error: error) }
        }
    }

    private static func reply(id: JSONValue, error: AutomationError) -> String {
        JSONValue.object([
            "jsonrpc": "2.0", "id": id,
            "error": ["code": .number(Double(error.code)), "message": .string(error.message)],
        ]).line
    }

    private func call(_ method: String, _ params: JSONValue, client: String) async throws(AutomationError)
        -> JSONValue
    {
        switch method {
        case "hello": ["app": "Blitter", "protocol": 1]
        case "state": automationState
        case "listing": try listing(params)
        case "actions": try actionList(params)
        case "navigate": try await navigate(params)
        case "select": try select(params)
        case "activate": try activate(params)
        case "preview": try previewJSON(params)
        case "run": try await runAutomated(params, client: client)
        case "showMenu": try showMenu(params)
        default: throw .unknownMethod(method)
        }
    }
}

// MARK: Reading and viewing

extension Workspace {
    var automationState: JSONValue {
        [
            "activeSide": .string(Self.name(of: activeSide)),
            "showsHiddenFiles": .bool(showsHiddenFiles),
            "sides": ["left": sideJSON(.left), "right": sideJSON(.right)],
        ]
    }

    func sideJSON(_ side: Side) -> JSONValue {
        let state = state(of: side)
        var object: [String: JSONValue] = [
            "location": .string(state.location),
            "listedLocation": .string(state.entriesLocation),
            "selection": .array(state.selection.sorted().map(JSONValue.string)),
            "sort": ["column": .string(state.sort.column.rawValue), "ascending": .bool(state.sort.ascending)],
            "items": .number(Double(state.visibleEntries.count)),
        ]
        switch state.status {
        case .loading: object["status"] = "loading"
        case .loaded: object["status"] = "loaded"
        case let .failed(message):
            object["status"] = "failed"
            object["error"] = .string(message)
        }
        if let find = state.find {
            object["search"] = ["root": .string(find.root), "pattern": .string(find.pattern),
                                "contains": .string(find.contents), "running": .bool(find.isRunning)]
        }
        return .object(object)
    }

    /// A page of the side's listing, as the list shows it (sorted, filtered).
    func listing(_ params: JSONValue) throws(AutomationError) -> JSONValue {
        let side = try sideParameter(params)
        let offset = max(0, params["offset"]?.int ?? 0)
        let limit = min(max(1, params["limit"]?.int ?? 1000), 5000)
        let state = state(of: side)
        let page = state.visibleEntries.dropFirst(offset).prefix(limit)
        let formatter = ISO8601DateFormatter()
        let entries: [JSONValue] = page.map { listed in
            let entry = listed.entry
            var object: [String: JSONValue] = [
                "name": .string(entry.name), "kind": .string(Self.kindName(entry.kind)),
                "size": .number(Double(entry.size)),
                "modified": .string(formatter.string(from: entry.modificationDate)),
                "hidden": .bool(entry.isHidden),
            ]
            if let bytes = state.folderSizes[entry.name]?.bytes {
                object["folderSize"] = .number(Double(bytes))
            }
            return .object(object)
        }
        return ["location": .string(state.entriesLocation), "total": .number(Double(state.visibleEntries.count)),
                "offset": .number(Double(offset)), "entries": .array(entries)]
    }

    /// The actions offered over the socket, and whether each can run on the side now.
    func actionList(_ params: JSONValue) throws(AutomationError) -> JSONValue {
        let side = try sideParameter(params)
        return .array(actionRegistry.all.filter { $0.effect != .notAutomated }.map { action in
            ["id": .string(action.id), "title": .string(action.title), "effect": .string(action.effect.rawValue),
             "runnable": .bool(canRun(action.id, on: side))]
        })
    }

    /// Goes to a path and answers once the side has read it (or could not), or after 30 seconds.
    func navigate(_ params: JSONValue) async throws(AutomationError) -> JSONValue {
        let side = try sideParameter(params)
        guard let path = params["path"]?.string, !path.isEmpty else {
            throw .invalidParams("navigate needs a path.")
        }
        perform(.navigate(side, path: path))
        for _ in 0 ..< 1500 where !Task.isCancelled {
            let state = state(of: side)
            if state.status != .loading, state.entriesLocation == state.location {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return sideJSON(side)
    }

    /// Selects exactly the given names among those listed; names not listed are returned apart.
    func select(_ params: JSONValue) throws(AutomationError) -> JSONValue {
        let side = try sideParameter(params)
        guard let list = params["names"]?.array, case let names = list.compactMap(\.string),
              names.count == list.count
        else {
            throw .invalidParams("select needs names, a list of names in the side's listing.")
        }
        let state = state(of: side)
        let listed = Set(names.filter { state.listed($0) != nil })
        perform(.select(side, listed))
        return ["selection": .array(listed.sorted().map(JSONValue.string)),
                "notListed": .array(names.filter { !listed.contains($0) }.map(JSONValue.string))]
    }

    func activate(_ params: JSONValue) throws(AutomationError) -> JSONValue {
        let side = try sideParameter(params)
        perform(.activate(side))
        return ["activeSide": .string(Self.name(of: side))]
    }

    // MARK: Parameters

    /// The side a request names ("left" or "right"); the active side if it names none.
    func sideParameter(_ params: JSONValue) throws(AutomationError) -> Side {
        try Self.side(params, active: activeSide)
    }

    static func side(_ params: JSONValue, active: Side? = nil) throws(AutomationError) -> Side {
        switch params["side"] {
        case "left"?: return .left
        case "right"?: return .right
        case nil:
            guard let active else {
                throw .invalidParams("side must be “left” or “right”.")
            }
            return active
        default: throw .invalidParams("side must be “left” or “right”.")
        }
    }

    static func name(of side: Side) -> String {
        side == .left ? "left" : "right"
    }

    static func kindName(_ kind: DirectoryEntry.Kind) -> String {
        switch kind {
        case .file: "file"
        case .directory: "folder"
        case .symlink: "link"
        case .other: "other"
        }
    }
}
