import Foundation

/// `blitter [--new] [PATH [PATH]]` (#98): show folders in Blitter from a terminal.
///
///     blitter .                 the active side shows the current folder
///     blitter ~/a ~/b           left side ~/a, right side ~/b
///     blitter --new             a new window (both sides at the active side's folder)
///     blitter --new ~/a [~/b]   a new window, both sides at ~/a (or left ~/a, right ~/b)
///     blitter ~/notes.txt       a file: its folder, the file selected
///
/// Paths are taken in the terminal's folder. The tool's commands (`state`, `run`, …) win over a
/// folder of that name: `./state` shows the folder.
public struct ShowFolders: Equatable, Sendable {
    /// What a path names on disk; an app or other package is shown as the item it is, in its folder.
    public enum Kind: Sendable {
        case folder, item, missing
    }

    /// A folder to show, and the item in it to select.
    public struct Target: Equatable, Sendable {
        public let folder: String
        public let selecting: String?
    }

    public let newWindow: Bool
    public let targets: [Target]

    /// The words that are the tool's commands, not paths.
    static let commands: Set = ["state", "hello", "listing", "actions", "navigate", "select", "activate", "preview",
                                "run", "call", "mcp", "help", "-h", "--help"]

    /// This syntax, or nil for a command of the tool (or nothing at all: the usage).
    public static func parse(_ arguments: [String], in folder: String, home: String,
                             kind: (String) -> Kind) throws(AutomationCommandLine.Usage) -> ShowFolders?
    {
        guard let first = arguments.first, !commands.contains(first) else {
            return nil
        }
        let newWindow = first == "--new"
        let paths = Array(arguments.dropFirst(newWindow ? 1 : 0))
        if let option = paths.first(where: { $0.hasPrefix("-") }) {
            throw AutomationCommandLine.Usage(message: "blitter: unknown option “\(option)”.\n"
                + AutomationCommandLine.help)
        }
        guard paths.count <= 2 else {
            throw AutomationCommandLine.Usage(message: "blitter: at most two folders, one per side.")
        }
        var targets: [Target] = []
        for path in paths {
            let absolute = resolve(path, in: folder, home: home)
            switch kind(absolute) {
            case .folder:
                targets.append(Target(folder: absolute, selecting: nil))
            case .item:
                targets.append(Target(folder: (absolute as NSString).deletingLastPathComponent,
                                      selecting: (absolute as NSString).lastPathComponent))
            case .missing:
                throw AutomationCommandLine.Usage(message: "blitter: “\(path)”: no such file or folder.")
            }
        }
        return ShowFolders(newWindow: newWindow, targets: targets)
    }

    /// "~", "~/x", relative to `folder`, or absolute; ".." and "." taken out.
    static func resolve(_ path: String, in folder: String, home: String) -> String {
        let expanded = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst() : path
        let absolute = expanded.hasPrefix("/") ? expanded : folder + "/" + expanded
        return URL(fileURLWithPath: absolute).standardizedFileURL.path
    }

    /// What a path is on this Mac.
    public static func kind(of path: String) -> Kind {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else {
            return .missing
        }
        let isPackage = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
        return isFolder.boolValue && !isPackage ? .folder : .item
    }

    /// The requests, in order: the new window first (it is the window in front then), then each
    /// side's folder and the item to select there. One folder: the active side's — in a new
    /// window, both sides'.
    public var requests: [(method: String, params: JSONValue)] {
        var requests: [(method: String, params: JSONValue)] = []
        if newWindow {
            requests.append(("run", ["action": "new-window"]))
        }
        let sides: [(side: String?, target: Target)] = switch (targets.count, newWindow) {
        case (0, _): []
        case (1, false): [(nil, targets[0])]
        case (1, true): [("left", targets[0]), ("right", targets[0])]
        default: [("left", targets[0]), ("right", targets[1])]
        }
        for (side, target) in sides {
            var navigate: [String: JSONValue] = ["path": .string(target.folder)]
            navigate["side"] = side.map(JSONValue.string)
            requests.append(("navigate", .object(navigate)))
            if let name = target.selecting {
                // Shown even if hidden or filtered out: it was asked for by name (#98 review).
                var select: [String: JSONValue] = ["names": [.string(name)], "reveal": true]
                select["side"] = side.map(JSONValue.string)
                requests.append(("select", .object(select)))
            }
        }
        return requests
    }

    /// Sends the requests on one connection, one after the other; nil if all were done, else
    /// why not — and nothing more is sent after a request that did not do what it should.
    public func perform(with client: AutomationClient) throws -> String? {
        for (method, params) in requests {
            let reply = try client.call(method, params)
            if let error = reply["error"] {
                return "blitter: \(error["message"]?.string ?? "error") (code \(error["code"]?.int ?? 0))"
            }
            if let problem = Self.problem(method, params, reply["result"] ?? .null) {
                return problem
            }
        }
        return nil
    }

    /// A folder that could not be read or was still being read when Blitter answered (#98
    /// review), or an item that is not there to select.
    static func problem(_ method: String, _ params: JSONValue, _ result: JSONValue) -> String? {
        switch method {
        case "navigate":
            let path = params["path"]?.string ?? ""
            return switch result["status"]?.string {
            case "loaded": nil
            case "failed": "blitter: \(path): \(result["error"]?.string ?? "it could not be read.")"
            default: "blitter: \(path) is still being read; try again in a moment."
            }
        case "select":
            let missing = result["notListed"]?.array?.compactMap(\.string) ?? []
            return missing.isEmpty ? nil : "blitter: “\(missing.joined(separator: "”, “"))” is not there to select."
        default:
            return nil
        }
    }
}
